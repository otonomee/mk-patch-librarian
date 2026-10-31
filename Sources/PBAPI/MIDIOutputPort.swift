import Foundation
import CoreMIDI

// MARK: - Device Description

/// Describes one MIDI endpoint (source or destination) belonging to a device.
/// `portID` is the underlying `MIDIEndpointRef` and is what callers pass back
/// as the `deviceID` argument of the send methods.
public struct MIDIPortInfo: Identifiable, Hashable {

    public let deviceRef: MIDIDeviceRef
    public let entityRef: MIDIEntityRef
    public let portRef: MIDIEndpointRef

    public let name: String
    public let manufacturer: String?
    public let model: String?

    /// True for a source endpoint (the synth transmits from it; we receive on it).
    public let isSource: Bool
    /// True for a destination endpoint (the synth receives on it; we transmit to it).
    public let isDestination: Bool

    public var id: UInt32 { portRef }
    public var portID: UInt32 { portRef }

    public var displayName: String {
        let direction = isDestination ? "in" : (isSource ? "out" : "?")
        return "\(name) (\(direction))"
    }

    public static func == (lhs: MIDIPortInfo, rhs: MIDIPortInfo) -> Bool {
        lhs.portRef == rhs.portRef
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(portRef)
    }
}

// MARK: - MIDI Error Handling

public enum MIDIError: LocalizedError {
    case notInitialized
    case noDevice
    case system(OSStatus)
    case timeout
    case invalidMessage(String)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "MIDI subsystem is not initialized"
        case .noDevice:
            return "No MIDI device connected"
        case .system(let status):
            let fourCC = MIDIError.fourCharCode(status)
            return "CoreMIDI error \(fourCC) (\(status))"
        case .timeout:
            return "Timed out waiting for a SysEx response"
        case .invalidMessage(let reason):
            return "Invalid MIDI message: \(reason)"
        }
    }

    /// Render an OSStatus as the four-char-code CoreMIDI reports it as.
    private static func fourCharCode(_ status: OSStatus) -> String {
        let u = UInt32(bitPattern: status)
        let bytes: [UInt8] = [
            UInt8((u >> 24) & 0xFF),
            UInt8((u >> 16) & 0xFF),
            UInt8((u >> 8) & 0xFF),
            UInt8(u & 0xFF),
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "????"
    }
}

// MARK: - MIDI Output Port

/// CoreMIDI-backed transport for talking to the synthesizer.
///
/// Usage:
///   1. `MIDIOutputPort.initialize()` once at launch.
///   2. `MIDIOutputPort.getConnectedDevices()` to enumerate endpoints.
///   3. `MIDIOutputPort.select(device:)` to pick a destination (optional —
///      the first destination is auto-selected on initialize).
///   4. `MIDIOutputPort.sendSysEx(...)` / `sendMIDIPacket(...)`.
public enum MIDIOutputPort {

    // MARK: Static state

    private static var client: MIDIClientRef = 0
    private static var outputPort: MIDIPortRef = 0
    private static var inputPort: MIDIPortRef = 0

    private static var selectedDestination: MIDIEndpointRef = 0
    private static var connectedSource: MIDIEndpointRef = 0

    /// Raw bytes received from the synth, waiting to be framed into messages.
    private static var receiveBuffer: [UInt8] = []
    private static let receiveLock = NSLock()

    // MARK: Lifecycle

    /// Create the CoreMIDI client and ports. Safe to call repeatedly.
    public static func initialize() -> Bool {
        if client != 0 { return true }

        var newClient: MIDIClientRef = 0
        var status = MIDIClientCreateWithBlock(
            "MK Patch Librarian" as CFString,
            &newClient
        ) { _ in
            // Device list changed. Enumeration is lazy, so nothing to do here;
            // callers refresh with getConnectedDevices().
        }
        guard status == noErr else {
            print("MIDIClientCreateWithBlock failed: \(MIDIError.system(status).localizedDescription)")
            return false
        }
        client = newClient

        var newOutPort: MIDIPortRef = 0
        status = MIDIOutputPortCreate(client, "MK Patch Librarian out" as CFString, &newOutPort)
        guard status == noErr else {
            print("MIDIOutputPortCreate failed: \(MIDIError.system(status).localizedDescription)")
            return false
        }
        outputPort = newOutPort

        var newInPort: MIDIPortRef = 0
        status = MIDIInputPortCreateWithBlock(
            client,
            "MK Patch Librarian in" as CFString,
            &newInPort
        ) { packetList, _ in
            ingest(packetList: packetList)
        }
        guard status == noErr else {
            print("MIDIInputPortCreateWithBlock failed: \(MIDIError.system(status).localizedDescription)")
            return false
        }
        inputPort = newInPort

        print("MIDI initialized (client \(client), out \(outputPort), in \(inputPort))")

        // Auto-select the first destination we can find so simple send flows work.
        if let first = getConnectedDevices().first(where: { $0.isDestination }) {
            select(device: first)
        }
        return true
    }

    /// Tear down the connection to the current device (keeps client alive).
    public static func disconnect() {
        if connectedSource != 0 {
            MIDIPortDisconnectSource(inputPort, connectedSource)
            connectedSource = 0
        }
        selectedDestination = 0
        receiveLock.lock()
        receiveBuffer.removeAll()
        receiveLock.unlock()
        print("Disconnected from MIDI device")
    }

    // MARK: Enumeration

    /// Enumerate every source and destination endpoint on every device.
    public static func getConnectedDevices() -> [MIDIPortInfo] {
        var results: [MIDIPortInfo] = []

        let deviceCount = MIDIGetNumberOfDevices()
        for deviceIndex in 0..<deviceCount {
            let device = MIDIGetDevice(deviceIndex)
            guard device != 0 else { continue }

            let deviceName = stringProperty(device, kMIDIPropertyDisplayName) ?? "Device \(deviceIndex)"
            let manufacturer = stringProperty(device, kMIDIPropertyManufacturer)
            let model = stringProperty(device, kMIDIPropertyModel)

            let entityCount = MIDIDeviceGetNumberOfEntities(device) // returns ItemCount == Int in Swift
            for entityIndex in 0..<entityCount {
                let entity = MIDIDeviceGetEntity(device, entityIndex)
                guard entity != 0 else { continue }

                // Sources: endpoints this device transmits on (we receive from them).
                let sourceCount = MIDIEntityGetNumberOfSources(entity)
                for sourceIndex in 0..<sourceCount {
                    let endpoint = MIDIEntityGetSource(entity, sourceIndex)
                    guard endpoint != 0 else { continue }
                    let name = stringProperty(endpoint, kMIDIPropertyDisplayName) ?? deviceName
                    results.append(MIDIPortInfo(
                        deviceRef: device,
                        entityRef: entity,
                        portRef: endpoint,
                        name: name,
                        manufacturer: manufacturer,
                        model: model,
                        isSource: true,
                        isDestination: false
                    ))
                }

                // Destinations: endpoints this device receives on (we transmit to them).
                let destCount = MIDIEntityGetNumberOfDestinations(entity)
                for destIndex in 0..<destCount {
                    let endpoint = MIDIEntityGetDestination(entity, destIndex)
                    guard endpoint != 0 else { continue }
                    let name = stringProperty(endpoint, kMIDIPropertyDisplayName) ?? deviceName
                    results.append(MIDIPortInfo(
                        deviceRef: device,
                        entityRef: entity,
                        portRef: endpoint,
                        name: name,
                        manufacturer: manufacturer,
                        model: model,
                        isSource: false,
                        isDestination: true
                    ))
                }
            }
        }

        return results
    }

    /// Select the destination endpoint to send to and, if present, connect the
    /// matching source endpoint so SysEx responses are received.
    public static func select(device info: MIDIPortInfo) {
        guard info.isDestination else {
            print("select(device:) ignored: \(info.displayName) is not a destination")
            return
        }

        if connectedSource != 0 {
            MIDIPortDisconnectSource(inputPort, connectedSource)
            connectedSource = 0
        }

        selectedDestination = info.portRef
        print("Selected destination: \(info.displayName)")

        // Find the source endpoint on the same device so we can receive replies.
        if let source = getConnectedDevices().first(where: {
            $0.isSource && $0.deviceRef == info.deviceRef
        }) {
            let status = MIDIPortConnectSource(inputPort, source.portRef, nil)
            if status == noErr {
                connectedSource = source.portRef
                print("Connected source: \(source.displayName)")
            } else {
                print("MIDIPortConnectSource failed: \(MIDIError.system(status).localizedDescription)")
            }
        } else {
            print("No source endpoint found on \(info.name); SysEx replies will not be received")
        }
    }

    // MARK: Sending

    /// Send a raw MIDI message (SysEx or otherwise) to the selected destination.
    public static func sendMIDIPacket(
        deviceID: UInt32,
        channel: Int,
        message: [UInt8],
        completion: @escaping (Result<[UInt8], Error>) -> Void
    ) {
        _ = channel // SysEx is channel-agnostic; kept for API compatibility.

        guard ensureReady(deviceID: deviceID, completion: completion) else { return }

        let status = send(bytes: message)
        if status == noErr {
            completion(.success(message))
        } else {
            completion(.failure(MIDIError.system(status)))
        }
    }

    /// Send a SysEx request and wait (on a background queue) for the first
    /// complete SysEx reply from the synth, or fail with `.timeout`.
    ///
    /// `accepting` may veto frames: a vetoed frame is discarded and polling
    /// continues (used to skip the stale `0x23`/`0x24` load-ack of a
    /// back-to-back `0x40` while waiting for a `0x11`'s `0x21`/`0x22`).
    public static func sendSysEx(
        deviceID: UInt32,
        channel: Int,
        data: [UInt8],
        timeout: TimeInterval = 5.0,
        accepting: (([UInt8]) -> Bool)? = nil,
        completion: @escaping (Result<[UInt8], Error>) -> Void
    ) {
        _ = channel // kept for API compatibility.

        guard ensureReady(deviceID: deviceID, completion: completion) else { return }

        // Drop any stale partial data before the new exchange.
        receiveLock.lock()
        receiveBuffer.removeAll()
        receiveLock.unlock()

        let status = send(bytes: data)
        guard status == noErr else {
            completion(.failure(MIDIError.system(status)))
            return
        }
        print("SysEx sent (\(data.count) bytes), waiting up to \(timeout)s for reply")

        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                while let frame = takeCompletedSysEx() {
                    if accepting?(frame) ?? true {
                        completion(.success(frame))
                        return
                    }
                    // Vetoed (stale ack of an earlier request): discarded by
                    // takeCompletedSysEx; keep waiting for the real reply.
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            completion(.failure(MIDIError.timeout))
        }
    }

    /// Send a request and capture EVERY byte that arrives afterwards, rather
    /// than stopping at the first F0..F7 frame.
    ///
    /// Used to diagnose multi-frame replies (the 37 KB bank dump may be split
    /// by the synth). Returns once `timeout` expires or once a complete frame
    /// has arrived and the line has been quiet for `quietInterval`.
    public static func sendAndCapture(
        deviceID: UInt32,
        data: [UInt8],
        timeout: TimeInterval,
        quietInterval: TimeInterval = 0.75,
        completion: @escaping (Result<[UInt8], Error>) -> Void
    ) {
        guard ensureReady(deviceID: deviceID, completion: completion) else { return }

        receiveLock.lock()
        receiveBuffer.removeAll()
        receiveLock.unlock()

        let status = send(bytes: data)
        guard status == noErr else {
            completion(.failure(MIDIError.system(status)))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(timeout)
            var lastCount = -1
            var lastChange = Date()
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
                let snapshot = bufferSnapshot()
                if snapshot.count != lastCount {
                    lastCount = snapshot.count
                    lastChange = Date()
                }
                let sawCompleteFrame = snapshot.first == 0xF0 && snapshot.last == 0xF7
                if sawCompleteFrame && Date().timeIntervalSince(lastChange) >= quietInterval {
                    completion(.success(snapshot))
                    return
                }
            }
            // Deadline: hand back whatever arrived so it can be analyzed.
            let snapshot = bufferSnapshot()
            if snapshot.isEmpty {
                completion(.failure(MIDIError.timeout))
            } else {
                completion(.success(snapshot))
            }
        }
    }

    /// Copy of the raw receive buffer (for capture/diagnostics).
    private static func bufferSnapshot() -> [UInt8] {
        receiveLock.lock()
        defer { receiveLock.unlock() }
        return receiveBuffer
    }

    // MARK: Internals

    /// Shared guard: ensures the stack is initialized and a destination is set.
    private static func ensureReady<T>(
        deviceID: UInt32,
        completion: @escaping (Result<T, Error>) -> Void
    ) -> Bool {
        if client == 0, !initialize() {
            completion(.failure(MIDIError.notInitialized))
            return false
        }
        if deviceID != 0 {
            selectedDestination = MIDIEndpointRef(deviceID)
        }
        guard selectedDestination != 0 else {
            completion(.failure(MIDIError.noDevice))
            return false
        }
        return true
    }

    /// Low-level send: wraps `bytes` in a one-packet MIDIPacketList and sends it.
    /// Large SysEx messages (bank dumps) are kept in a single logical packet;
    /// CoreMIDI fragments transport-level as needed.
    private static func send(bytes: [UInt8]) -> OSStatus {
        guard outputPort != 0 else { return OSStatus(kMIDIInvalidPort) }
        guard selectedDestination != 0 else { return OSStatus(kMIDIUnknownEndpoint) }
        guard !bytes.isEmpty else { return OSStatus(kMIDIMessageSendErr) }

        // MIDIPacketList holds a fixed inline buffer; allocate heap room for
        // the header plus our payload plus alignment padding.
        let capacity = MemoryLayout<MIDIPacketList>.size + bytes.count + 8
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: capacity,
            alignment: MemoryLayout<MIDIPacketList>.alignment
        )
        defer { raw.deallocate() }

        let packetList = raw.assumingMemoryBound(to: MIDIPacketList.self)
        let firstPacket = MIDIPacketListInit(packetList)

        let added: Bool = bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            MIDIPacketListAdd(
                packetList,
                capacity,    // listSize: ByteCount == Int in Swift
                firstPacket, // curPacket: pointer from MIDIPacketListInit
                0,           // timestamp: now
                bytes.count, // nData: ByteCount == Int in Swift
                base         // data
            )
            return true
        }
        guard added else { return OSStatus(kMIDIMessageSendErr) }

        return MIDISend(outputPort, selectedDestination, packetList)
    }

    /// Called from the CoreMIDI read block (on a realtime thread — keep it light).
    private static func ingest(packetList: UnsafePointer<MIDIPacketList>) {
        let packetCount = Int(packetList.pointee.numPackets)
        guard packetCount > 0 else { return }

        // Walk packets by pointer: SysEx larger than one MIDIPacket's inline
        // storage spans multiple packets, so a struct copy would truncate.
        let packetFieldOffset = MemoryLayout<MIDIPacketList>.offset(of: \MIDIPacketList.packet)!
        var packetRaw = UnsafeRawPointer(packetList).advanced(by: packetFieldOffset)

        var incoming: [UInt8] = []
        for _ in 0..<packetCount {
            let packet = packetRaw.assumingMemoryBound(to: MIDIPacket.self)
            let length = Int(packet.pointee.length)

            let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!
            let dataPtr = packetRaw.advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)
            incoming.append(contentsOf: UnsafeBufferPointer(start: dataPtr, count: length))

            // Advance to the next packet, honoring CoreMIDI's 4-byte alignment.
            let endAddress = Int(bitPattern: packetRaw) + dataOffset + length
            let aligned = (endAddress + 3) & ~3
            guard let nextRaw = UnsafeRawPointer(bitPattern: aligned) else { break }
            packetRaw = nextRaw
        }

        guard !incoming.isEmpty else { return }
        receiveLock.lock()
        // Real-time messages (MIDI clock F8, active sensing FE, transport
        // FA-FF, ...) may be interleaved at ANY point inside a SysEx stream.
        // They are not part of the payload and have bit 7 set, which would
        // both inflate the byte count and corrupt 7-to-8 decoding. Drop them.
        receiveBuffer.append(contentsOf: stripRealtime(incoming))
        receiveLock.unlock()
    }

    /// Remove bytes that cannot legally appear inside a SysEx payload
    /// (system real-time 0xF8...0xFF). Exposed for tests.
    static func stripRealtime(_ bytes: [UInt8]) -> [UInt8] {
        bytes.filter { $0 < 0xF8 }
    }

    /// Extract one complete F0..F7 SysEx message from the receive buffer, if present.
    private static func takeCompletedSysEx() -> [UInt8]? {
        receiveLock.lock()
        defer { receiveLock.unlock() }

        // Discard anything before the first F0 (running status garbage).
        guard let start = receiveBuffer.firstIndex(of: 0xF0) else {
            receiveBuffer.removeAll()
            return nil
        }
        if start > 0 {
            receiveBuffer.removeFirst(start)
        }
        guard let end = receiveBuffer.firstIndex(of: 0xF7) else { return nil }

        let message = Array(receiveBuffer[receiveBuffer.startIndex...end])
        receiveBuffer.removeSubrange(receiveBuffer.startIndex...end)
        return message
    }

    /// Read a string property off a CoreMIDI object.
    private static func stringProperty(_ object: MIDIObjectRef, _ property: CFString) -> String? {
        var unmanaged: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, property, &unmanaged) == noErr,
              let value = unmanaged else { return nil }
        return value.takeRetainedValue() as String
    }
}
