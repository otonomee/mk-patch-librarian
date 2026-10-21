import Foundation
import CoreMIDI

/// Resolves the MIDI destination that a Korg synth is actually reachable on.
///
/// Why this exists: the MicroKORG is normally connected over 5-pin DIN behind
/// a USB MIDI interface (Roland UM-ONE here), so CoreMIDI only ever shows the
/// *interface's* endpoints — never the words "MicroKORG". Name matching alone
/// therefore finds nothing. The locator:
///
///   1. tries endpoints whose name/manufacturer/model mentions Korg, and
///   2. falls back to a read-only probe: send the `0x10` current-program
///      request to each remaining destination and accept the first one that
///      answers with a `0x40` dump. `0x10` is inert on anything that is not a
///      Korg, so probing cannot disturb other gear.
///
/// A successful resolution is cached until the endpoint disappears.
/// Concurrent callers during a search join it rather than starting a second
/// probe chain — two chains would fight over MIDIOutputPort's single
/// selected destination and receive buffer.
///
/// An optional preferred port (picked in Settings, persisted by name since
/// endpoint refs don't survive relaunch) is probed first. It is a hint, not
/// a lock: if the synth doesn't answer there the normal search continues.
public enum DeviceLocator {

    // MARK: Seams (tests swap these)

    static var enumerate: () -> [MIDIPortInfo] = MIDIOutputPort.getConnectedDevices
    static var probe: (MIDIPortInfo, TimeInterval, @escaping (Bool) -> Void) -> Void = liveProbe
    static var defaults: UserDefaults = .standard

    // MARK: Preferred port

    public static let preferredDestinationKey = "preferredMIDIDestination"

    public static var preferredDestinationName: String? {
        get { defaults.string(forKey: preferredDestinationKey) }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: preferredDestinationKey)
            } else {
                defaults.removeObject(forKey: preferredDestinationKey)
            }
        }
    }

    // MARK: Cache

    private static let lock = NSLock()
    private static var cached: MIDIPortInfo?
    /// Completions waiting on the search in flight; nil when idle.
    private static var waiting: [(Result<MIDIPortInfo, Error>) -> Void]?

    /// Drop the cached endpoint (tests, or after unplugging).
    public static func resetCache() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// The cached endpoint, if it still exists in CoreMIDI.
    public static func cachedDestination() -> MIDIPortInfo? {
        lock.lock()
        let saved = cached
        lock.unlock()
        guard let saved else { return nil }
        let live = enumerate()
            .first { $0.isDestination && $0.portRef == saved.portRef }
        if live == nil { resetCache() }
        return live
    }

    private static func store(_ info: MIDIPortInfo) {
        lock.lock()
        cached = info
        lock.unlock()
    }

    // MARK: Ordering (pure, testable)

    /// True when an endpoint identifies itself as (or is attached to) a Korg.
    public static func isKorgNamed(_ info: MIDIPortInfo) -> Bool {
        let haystack = "\(info.name) \(info.manufacturer ?? "") \(info.model ?? "")"
        return haystack.lowercased().contains("korg")
    }

    /// The preferred port (if named and present) first, then Korg-named
    /// destinations (skip probing), then everything else.
    public static func prioritize(_ endpoints: [MIDIPortInfo], preferredName: String? = nil) -> [MIDIPortInfo] {
        let destinations = endpoints.filter(\.isDestination)
        let preferred = destinations.filter { preferredName != nil && $0.name == preferredName }
        var seen = Set<MIDIEndpointRef>()
        let ordered = preferred + destinations.filter(isKorgNamed) + destinations.filter { !isKorgNamed($0) }
        return ordered.filter { seen.insert($0.portRef).inserted }
    }

    // MARK: Resolution

    /// Find a destination that answers the current-program request.
    ///
    /// Calls back on an arbitrary queue; callers hop to `main` themselves.
    public static func findDestination(
        // 2.5 s: a one-off 1.5 s miss on the UM-ONE probe was observed live
        // (same hardware answered the next run); DIN replies are ms-fast, so
        // the headroom absorbs transient latency without much extra worst case.
        timeout: TimeInterval = 2.5,
        // One full pass through every candidate can legitimately come up
        // empty — this is that same documented UM-ONE miss, not "no synth."
        // A bare retry fixed it every time it was hit live, so do that
        // automatically instead of surfacing a failure the user just has to
        // retry by hand. Bounded to 2 passes: a real disconnect still fails
        // in a reasonable time instead of 2.5s * candidate-count * passes.
        passes: Int = 2,
        completion: @escaping (Result<MIDIPortInfo, Error>) -> Void
    ) {
        if let cached = cachedDestination() {
            completion(.success(cached))
            return
        }
        lock.lock()
        if waiting != nil {
            waiting?.append(completion)
            lock.unlock()
            return
        }
        waiting = [completion]
        lock.unlock()

        var candidates = prioritize(enumerate(), preferredName: preferredDestinationName)
        // Measured live: the first probe sent to the UM-ONE in a session gets
        // no reply and the next one does. Retry a pinned port once right away
        // rather than sweeping every other port before coming back to it.
        if let first = candidates.first, first.name == preferredDestinationName {
            candidates.insert(first, at: 1)
        }
        guard !candidates.isEmpty else {
            finish(.failure(MIDIError.noDevice))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            attemptWithRetries(candidates, timeout: timeout, passesRemaining: passes, completion: finish)
        }
    }

    static var isSearching: Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiting != nil
    }

    private static func finish(_ result: Result<MIDIPortInfo, Error>) {
        lock.lock()
        let callers = waiting ?? []
        waiting = nil
        lock.unlock()
        callers.forEach { $0(result) }
    }

    private static func attemptWithRetries(
        _ candidates: [MIDIPortInfo],
        timeout: TimeInterval,
        passesRemaining: Int,
        completion: @escaping (Result<MIDIPortInfo, Error>) -> Void
    ) {
        attempt(candidates, timeout: timeout) { result in
            if case .failure = result, passesRemaining > 1 {
                attemptWithRetries(candidates, timeout: timeout, passesRemaining: passesRemaining - 1, completion: completion)
            } else {
                completion(result)
            }
        }
    }

    /// Probe candidates one at a time until one returns a `0x40` dump.
    private static func attempt(
        _ candidates: [MIDIPortInfo],
        timeout: TimeInterval,
        completion: @escaping (Result<MIDIPortInfo, Error>) -> Void
    ) {
        guard let head = candidates.first else {
            completion(.failure(MIDIError.noDevice))
            return
        }
        let rest = Array(candidates.dropFirst())

        // A Korg-named endpoint is trusted without spending a probe round trip.
        if isKorgNamed(head) {
            store(head)
            completion(.success(head))
            return
        }

        probe(head, timeout) { answered in
            if answered {
                store(head)
                completion(.success(head))
            } else {
                // Not a Korg (or silent): try the next destination.
                attempt(rest, timeout: timeout, completion: completion)
            }
        }
    }

    /// Send the inert `0x10` request and report whether a `0x40` came back.
    static func liveProbe(_ candidate: MIDIPortInfo, timeout: TimeInterval, done: @escaping (Bool) -> Void) {
        MIDIOutputPort.select(device: candidate)
        MIDIOutputPort.sendSysEx(
            deviceID: candidate.portRef,
            channel: 0,
            data: KorgSysEx.requestCurrentProgram(),
            timeout: timeout
        ) { result in
            if case .success(let raw) = result,
               let parsed = try? KorgSysEx.parse(raw),
               parsed.command == .currentProgramDump {
                done(true)
            } else {
                done(false)
            }
        }
    }
}
