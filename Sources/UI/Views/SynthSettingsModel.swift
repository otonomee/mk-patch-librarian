import Foundation
import Models
import PBAPI

/// State behind the Settings window's "Synth" section: reads the
/// microKORG's global block when the window opens, edits a draft, and writes
/// it back only on an explicit Save (ack-gated, then verified by read-back).
///
/// Callbacks are expected on the main queue; `Transport.live` hops there.
public final class SynthSettingsModel: ObservableObject {

    public struct Transport {
        public var read: (_ progress: @escaping (String) -> Void,
                          _ done: @escaping (Result<GlobalSettings, Error>) -> Void) -> Void
        public var write: (_ settings: GlobalSettings,
                           _ progress: @escaping (String) -> Void,
                           _ done: @escaping (Result<Void, Error>) -> Void) -> Void

        public init(
            read: @escaping (@escaping (String) -> Void, @escaping (Result<GlobalSettings, Error>) -> Void) -> Void,
            write: @escaping (GlobalSettings, @escaping (String) -> Void, @escaping (Result<Void, Error>) -> Void) -> Void
        ) {
            self.read = read
            self.write = write
        }
    }

    public enum Phase { case idle, reading, saving }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var baseline: GlobalSettings?
    @Published public private(set) var draft: GlobalSettings?
    @Published public private(set) var status: String?
    @Published public private(set) var statusIsError = false

    private let transport: Transport

    public init(transport: Transport = .live) {
        self.transport = transport
    }

    public var isLoaded: Bool { baseline != nil }
    public var isBusy: Bool { phase != .idle }
    public var isDirty: Bool { draft != baseline }
    public var canSave: Bool { isLoaded && isDirty && !isBusy }

    public func edit(_ change: (inout GlobalSettings) -> Void) {
        guard var settings = draft, !isBusy else { return }
        change(&settings)
        draft = settings
        setStatus(nil)
    }

    public func revert() {
        draft = baseline
        setStatus(nil)
    }

    public func load() {
        guard !isBusy else { return }
        phase = .reading
        setStatus("Finding synthesizer…")
        transport.read({ [weak self] in self?.setStatus($0) }) { [weak self] result in
            guard let self else { return }
            self.phase = .idle
            switch result {
            case .success(let settings):
                self.baseline = settings
                self.draft = settings
                self.setStatus(nil)
            case .failure(let error):
                self.setStatus("Read failed: \(Self.describe(error))", isError: true)
            }
        }
    }

    public func save() {
        guard canSave, let written = draft else { return }
        phase = .saving
        setStatus("Finding synthesizer…")
        transport.write(written, { [weak self] in self?.setStatus($0) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.phase = .idle
                self.setStatus("Save failed: \(Self.describe(error))", isError: true)
            case .success:
                self.baseline = written
                if written.midiChannel != KorgSysEx.channel {
                    self.phase = .idle
                    self.setStatus("Saved. The synth is now on MIDI channel \(written.midiChannel + 1) — "
                        + "MK Patch Librarian only talks on channel 1, so it can't reach the synth until "
                        + "you set it back on the hardware.", isError: true)
                    return
                }
                self.verify(written)
            }
        }
    }

    private func verify(_ written: GlobalSettings) {
        setStatus("Verifying…")
        transport.read({ _ in }) { [weak self] result in
            guard let self else { return }
            self.phase = .idle
            switch result {
            case .success(let readBack):
                self.baseline = readBack
                self.draft = readBack
                if Self.editableFieldsMatch(readBack, written) {
                    self.setStatus("Saved to microKORG")
                } else {
                    self.setStatus("Saved, but the synth reports different values — showing what it holds now",
                                   isError: true)
                }
            case .failure(let error):
                self.setStatus("Saved (acknowledged), but couldn't read back to verify: \(Self.describe(error))",
                               isError: true)
            }
        }
    }

    private func setStatus(_ text: String?, isError: Bool = false) {
        status = text
        statusIsError = isError
    }

    static func editableFieldsMatch(_ a: GlobalSettings, _ b: GlobalSettings) -> Bool {
        a.midiChannel == b.midiChannel && a.masterTune == b.masterTune
            && a.transpose == b.transpose && a.velocityCurve == b.velocityCurve
            && a.velocityValue == b.velocityValue && a.clock == b.clock
            && a.localControl == b.localControl && a.memoryProtect == b.memoryProtect
    }

    /// A read timeout almost always means the synth isn't on channel 1
    /// (found live in v17: it had been set to 8), so say so.
    static func describe(_ error: Error) -> String {
        if let midi = error as? MIDIError, case .timeout = midi {
            return "no reply from the synth. Check that its MIDI channel is set to channel 1."
        }
        return error.localizedDescription
    }
}

extension SynthSettingsModel.Transport {

    public static let live = SynthSettingsModel.Transport(
        read: { progress, done in
            withDestination(progress: progress, fail: done) { dest in
                progress("Reading settings…")
                PBAPI.SysExHandler.loadGlobal(deviceID: dest.portRef) { result in
                    let decoded = result.flatMap { data in
                        Result {
                            guard let settings = GlobalSettings(data: data) else {
                                throw KorgSysExError.wrongDataSize(expected: KorgSysEx.globalDataSize, got: data.count)
                            }
                            return settings
                        }
                    }
                    DispatchQueue.main.async { done(decoded) }
                }
            }
        },
        write: { settings, progress, done in
            withDestination(progress: progress, fail: done) { dest in
                progress("Saving…")
                PBAPI.SysExHandler.writeGlobal(deviceID: dest.portRef, data: settings.data) { result in
                    DispatchQueue.main.async { done(result) }
                }
            }
        }
    )

    private static func withDestination<T>(
        progress: @escaping (String) -> Void,
        fail: @escaping (Result<T, Error>) -> Void,
        then body: @escaping (MIDIPortInfo) -> Void
    ) {
        DeviceLocator.findDestination { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let dest): body(dest)
                case .failure(let error): fail(.failure(error))
                }
            }
        }
    }
}
