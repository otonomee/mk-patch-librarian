import Foundation
import CoreMIDI

/// PBAPI - Program/Bank API wrapper for Korg synthesizer communication
public enum PBAPI {
    
    /// Module types supported by the synthesizer
    public enum ModuleType: String, CaseIterable {
        case microkorg = "MicroKORG"
        case dw8k = "DW8K"
        case ex8k = "EX8K"
        case ms2000 = "MS2000/MS2K"
        case minilogue = "Minilogue"
        case prophecy = "Prophecy"
        case volcafmo = "VolcaFM/O"
        case blofeld = "Blofeld"
        
        public var displayName: String {
            switch self {
            case .microkorg: return "MicroKORG I/II/III/X"
            case .dw8k: return "DW8K"
            case .ex8k: return "EX8K"
            case .ms2000: return "MS2000 / MS2K"
            case .minilogue: return "Minilogue"
            case .prophecy: return "Prophecy"
            case .volcafmo: return "VolcaFM/O"
            case .blofeld: return "Blofeld"
            }
        }
    }
    
    /// SysEx message handler for Korg devices.
    ///
    /// Framing lives in `KorgSysEx`, which is verified against the reference
    /// dumps. This type is the transport layer on top of it: it sends a request
    /// and hands back the decoded reply.
    public struct SysExHandler {

        /// Pull the patch sitting in the synth's edit buffer.
        ///
        /// Sends `0x10` (request) and expects a `0x40` (dump) back. Note that
        /// sending `0x40` would *not* fetch anything -- it tells the synth to
        /// receive a patch.
        public static func loadCurrentProgram(
            deviceID: UInt32,
            timeout: TimeInterval = 5.0,
            completion: @escaping (Result<[UInt8], Error>) -> Void
        ) {
            exchange(
                deviceID: deviceID,
                request: KorgSysEx.requestCurrentProgram(),
                expecting: .currentProgramDump,
                timeout: timeout,
                completion: completion
            )
        }

        /// Pull all 128 programs (plus global, discarded). Returns the decoded
        /// 32512-byte bank.
        ///
        /// Uses the 0x0F ALL DATA request rather than the classic 0x1C PROGRAM
        /// DUMP REQUEST: measured on the microKORG S, bare 0x1C returns only a
        /// single 256-byte address-prefixed program and addressed variants get
        /// a 0x26 format error, while 0x0F returns one 0x50 frame of 32712
        /// decoded bytes (bank + global) in ~12 s at MIDI baud.
        ///
        /// A truncated reply (mid-stream byte loss on the 12 s transfer —
        /// measured once live: 32209/32712) is retried once before failing.
        public static func loadBank(
            deviceID: UInt32,
            timeout: TimeInterval = 45.0,
            completion: @escaping (Result<[UInt8], Error>) -> Void
        ) {
            loadBank(deviceID: deviceID, timeout: timeout, retriesLeft: 1,
                     completion: completion)
        }

        private static func loadBank(
            deviceID: UInt32,
            timeout: TimeInterval,
            retriesLeft: Int,
            completion: @escaping (Result<[UInt8], Error>) -> Void
        ) {
            exchange(
                deviceID: deviceID,
                request: KorgSysEx.requestAllData(),
                expecting: .allDataDump,
                timeout: timeout
            ) { result in
                switch result.flatMap({ data in
                    Result { try KorgSysEx.bank(fromAllData: data) }
                }) {
                case .success(let bank):
                    completion(.success(bank))
                case .failure(let error):
                    if case KorgSysExError.wrongDataSize = error, retriesLeft > 0 {
                        print("Bank reply truncated (\(error.localizedDescription)) — retrying")
                        loadBank(deviceID: deviceID, timeout: timeout,
                                 retriesLeft: retriesLeft - 1, completion: completion)
                    } else {
                        completion(.failure(error))
                    }
                }
            }
        }

        /// Pull the synth's global settings.
        ///
        /// A truncated reply is retried once, same policy as `loadBank`:
        /// measured live, the first global read after the synth was found
        /// once decoded to 137/200 bytes and an immediate re-read was clean.
        public static func loadGlobal(
            deviceID: UInt32,
            timeout: TimeInterval = 5.0,
            completion: @escaping (Result<[UInt8], Error>) -> Void
        ) {
            loadGlobal(deviceID: deviceID, timeout: timeout, retriesLeft: 1, completion: completion)
        }

        private static func loadGlobal(
            deviceID: UInt32,
            timeout: TimeInterval,
            retriesLeft: Int,
            completion: @escaping (Result<[UInt8], Error>) -> Void
        ) {
            exchange(
                deviceID: deviceID,
                request: KorgSysEx.requestGlobal(),
                expecting: .globalDump,
                timeout: timeout
            ) { result in
                if case .failure(let error) = result, case KorgSysExError.wrongDataSize = error, retriesLeft > 0 {
                    print("Global reply truncated (\(error.localizedDescription)) — retrying")
                    loadGlobal(deviceID: deviceID, timeout: timeout, retriesLeft: retriesLeft - 1,
                               completion: completion)
                } else {
                    completion(result)
                }
            }
        }

        /// Store 200 bytes of global settings (chart §9 `0x51`), ack-gated:
        /// succeeds only on `0x23` DATA LOAD COMPLETED.
        public static func writeGlobal(
            deviceID: UInt32,
            data: [UInt8],
            timeout: TimeInterval = 5.0,
            completion: @escaping (Result<Void, Error>) -> Void
        ) {
            let message: [UInt8]
            do {
                message = try KorgSysEx.sendGlobal(data)
            } catch {
                completion(.failure(error))
                return
            }
            MIDIOutputPort.sendSysEx(
                deviceID: deviceID,
                channel: 0,
                data: message,
                timeout: timeout,
                accepting: KorgSysEx.isDataLoadReply
            ) { result in
                switch result {
                case .failure(let error):
                    if let midiError = error as? MIDIError, case .timeout = midiError {
                        completion(.failure(KorgSysExError.dataLoadAckTimeout))
                    } else {
                        completion(.failure(error))
                    }
                case .success(let reply):
                    completion(Result { try KorgSysEx.dataLoadAck(reply) })
                }
            }
        }

        /// Push a 254-byte program into the edit buffer so it sounds immediately.
        /// This does not persist it; follow with `writeCurrentProgram` to commit.
        public static func sendCurrentProgram(
            deviceID: UInt32,
            data: [UInt8],
            completion: @escaping (Result<Bool, Error>) -> Void
        ) {
            do {
                let message = try KorgSysEx.sendCurrentProgram(data)
                MIDIOutputPort.sendMIDIPacket(
                    deviceID: deviceID,
                    channel: 0,
                    message: message
                ) { completion($0.map { _ in true }) }
            } catch {
                completion(.failure(error))
            }
        }

        /// Commit the edit buffer to slot `programIndex` (0...127). Nil keeps
        /// the synth's current front-panel selection (legacy behavior).
        ///
        /// Unlike a plain send, this waits for the write acknowledgement
        /// (chart §5: 0x11 -> §13 `0x21` WRITE COMPLETED or §14 `0x22`
        /// WRITE ERROR). Reading the ack is what lets a Protect-rejected
        /// write report failure instead of success; a deadline with no ack
        /// reports `KorgSysExError.writeAckTimeout`.
        public static func writeCurrentProgram(
            deviceID: UInt32,
            programIndex: Int? = nil,
            timeout: TimeInterval = 5.0,
            completion: @escaping (Result<Bool, Error>) -> Void
        ) {
            MIDIOutputPort.sendSysEx(
                deviceID: deviceID,
                channel: 0,
                data: KorgSysEx.writeCurrentProgram(to: programIndex),
                timeout: timeout,
                // The 0x40 that precedes this 0x11 in the save flow is acked
                // with 0x23/0x24; that ack may land while we wait — skip it.
                accepting: { !KorgSysEx.isLoadAck($0) }
            ) { result in
                switch result {
                case .failure(let error):
                    if let midiError = error as? MIDIError, case .timeout = midiError {
                        completion(.failure(KorgSysExError.writeAckTimeout))
                    } else {
                        completion(.failure(error))
                    }
                case .success(let reply):
                    let hex = reply.map { String(format: "%02X", $0) }.joined(separator: " ")
                    do {
                        let ack = try KorgSysEx.writeAck(reply)
                        print(String(format: "Write ack: %@ (0x%02X)", hex, ack.rawValue))
                        completion(.success(true))
                    } catch {
                        print("Write ack: \(hex) — \(error.localizedDescription)")
                        completion(.failure(error))
                    }
                }
            }
        }

        /// Read the 128 program names out of a bank without a second round trip.
        public static func programNames(inBank bank: [UInt8]) throws -> [String] {
            try KorgSysEx.programNames(inBank: bank)
        }

        /// Select a C/D program by bank select, send the editor bytes, then
        /// commit with an unaddressed 0x11 write (which targets the synth's
        /// current panel selection).
        ///
        /// C and D sit beyond the 0x0F ALL DATA dump. The save sequence is:
        ///   1. Bank select (CC0=0, CC32=1, PC=n) to make the target slot the
        ///      synth's current selection.
        ///   2. Short settle delay.
        ///   3. `sendCurrentProgram` pushes the 254 bytes into the edit buffer.
        ///   4. `writeCurrentProgram(nil)` sends an unaddressed 0x11; the
        ///      synth writes the edit buffer into whichever slot is currently
        ///      selected, i.e. the C/D slot from step 1.
        ///
        /// This mirrors the panel workflow: select slot, then save. Like the
        /// A/B save path, it waits for the 0x21/0x22 ack.
        public static func saveExtraProgram(
            deviceID: UInt32,
            lsb: Int,
            programChange: Int,
            data: [UInt8],
            completion: @escaping (Result<Bool, Error>) -> Void
        ) {
            let steps: [[UInt8]] = [
                [0xB0, 0x00, UInt8(clamping: 0)],                 // CC0  = bank MSB
                [0xB0, 0x20, UInt8(clamping: lsb)],               // CC32 = bank LSB
                [0xC0, UInt8(clamping: programChange)],           // Program Change
            ]
            func sendStep(_ i: Int) {
                guard i < steps.count else {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        sendCurrentProgram(deviceID: deviceID, data: data) { sent in
                            DispatchQueue.main.async {
                                switch sent {
                                case .failure(let error):
                                    completion(.failure(error))
                                case .success:
                                    writeCurrentProgram(
                                        deviceID: deviceID,
                                        programIndex: nil,
                                        completion: completion
                                    )
                                }
                            }
                        }
                    }
                    return
                }
                MIDIOutputPort.sendMIDIPacket(
                    deviceID: deviceID, channel: 0, message: steps[i]
                ) { result in
                    if case .failure(let error) = result {
                        completion(.failure(error))
                        return
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                        sendStep(i + 1)
                    }
                }
            }
            sendStep(0)
        }

        /// Select a C/D program by bank select, then read it back.
        ///
        /// C and D sit beyond the 0x0F ALL DATA dump, so the only way to one
        /// is bank select (CC0=0, CC32=lsb, PC=n) followed by an edit buffer
        /// read (HANDOFF-v10 §2a). The three CC/PC bytes go out with a short
        /// gap so the synth latches the bank before the program change, then
        /// a settle delay, then the 0x10 read. This CHANGES THE SYNTH'S
        /// SELECTED PROGRAM (it is not a write — nothing is stored).
        public static func loadExtraProgram(
            deviceID: UInt32,
            lsb: Int,
            programChange: Int,
            completion: @escaping (Result<[UInt8], Error>) -> Void
        ) {
            let steps: [[UInt8]] = [
                [0xB0, 0x00, UInt8(clamping: 0)],                 // CC0  = bank MSB
                [0xB0, 0x20, UInt8(clamping: lsb)],               // CC32 = bank LSB
                [0xC0, UInt8(clamping: programChange)],           // Program Change
            ]
            func sendStep(_ i: Int) {
                guard i < steps.count else {
                    // Let the panel settle, then read the edit buffer.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        loadCurrentProgram(deviceID: deviceID, completion: completion)
                    }
                    return
                }
                MIDIOutputPort.sendMIDIPacket(
                    deviceID: deviceID, channel: 0, message: steps[i]
                ) { result in
                    if case .failure(let error) = result {
                        completion(.failure(error))
                        return
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                        sendStep(i + 1)
                    }
                }
            }
            sendStep(0)
        }

        // MARK: Internals

        /// Send a request, validate the reply's header, and return decoded data.
        private static func exchange(
            deviceID: UInt32,
            request: [UInt8],
            expecting: KorgSysEx.Command,
            timeout: TimeInterval,
            completion: @escaping (Result<[UInt8], Error>) -> Void
        ) {
            MIDIOutputPort.sendSysEx(
                deviceID: deviceID,
                channel: 0,
                data: request,
                timeout: timeout
            ) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let reply):
                    do {
                        let parsed = try KorgSysEx.parse(reply)
                        guard parsed.command == expecting else {
                            completion(.failure(
                                parsed.command.isError
                                    ? KorgSysExError.deviceReportedError(parsed.command.rawValue)
                                    : KorgSysExError.unexpectedReply(
                                        expected: expecting.rawValue,
                                        got: parsed.command.rawValue
                                      )
                            ))
                            return
                        }
                        completion(.success(parsed.data))
                    } catch {
                        completion(.failure(error))
                    }
                }
            }
        }
    }
    
    /// Plain Note On/Off — not SysEx, just a 3-byte channel voice message.
    /// Used by the editor's audition keyboard to play the patch currently
    /// loaded on the synth.
    public struct NoteHandler {

        /// The raw 3-byte Note On message, clamped to valid MIDI ranges.
        /// Pure and separately testable — `noteOn` below just sends it.
        public static func noteOnMessage(channel: Int, note: Int, velocity: Int = 100) -> [UInt8] {
            let ch = UInt8(clamping: max(0, min(15, channel)))
            let n = UInt8(clamping: max(0, min(127, note)))
            let v = UInt8(clamping: max(1, min(127, velocity)))
            return [0x90 | ch, n, v]
        }

        /// The raw 3-byte Note Off message — a real note-off, not Note On
        /// with velocity 0, so it can never be mistaken for a (re)trigger.
        public static func noteOffMessage(channel: Int, note: Int) -> [UInt8] {
            let ch = UInt8(clamping: max(0, min(15, channel)))
            let n = UInt8(clamping: max(0, min(127, note)))
            return [0x80 | ch, n, 0]
        }

        /// Send Note On (0x9n). `channel` is 0-15 (MIDI channel 1-16).
        public static func noteOn(
            deviceID: UInt32,
            channel: Int,
            note: Int,
            velocity: Int = 100,
            completion: @escaping (Result<Void, Error>) -> Void = { _ in }
        ) {
            MIDIOutputPort.sendMIDIPacket(
                deviceID: deviceID, channel: channel, message: noteOnMessage(channel: channel, note: note, velocity: velocity)
            ) { result in
                completion(result.map { _ in () })
            }
        }

        /// Send Note Off (0x8n).
        public static func noteOff(
            deviceID: UInt32,
            channel: Int,
            note: Int,
            completion: @escaping (Result<Void, Error>) -> Void = { _ in }
        ) {
            MIDIOutputPort.sendMIDIPacket(
                deviceID: deviceID, channel: channel, message: noteOffMessage(channel: channel, note: note)
            ) { result in
                completion(result.map { _ in () })
            }
        }
    }

    /// MIDI device management
    public final class DeviceManager {
        
        public static let shared = DeviceManager()
        
        private var devices: [MIDIPortInfo] = []
        private var selectedDevice: MIDIPortInfo?
        
        public init() {}
        
        public func refreshDevices() {
            devices = MIDIOutputPort.getConnectedDevices()
            
            if devices.isEmpty {
                print("No MIDI devices connected")
            } else {
                print("Found \(devices.count) MIDI device(s)")
                
                // Auto-select first device or user-selected
                selectedDevice = devices.first
            }
        }
        
        public var selectedDeviceID: UInt32? {
            return selectedDevice?.portID
        }
        
        public func selectDevice(_ device: MIDIPortInfo) {
            selectedDevice = device
            print("Selected device: \(device.name)")
        }
    }
    
    /// Global patch manager (singleton pattern from PBCore)
    public final class PatchManager {
        
        public static let shared = PatchManager()
        
        private var patches: [String: [UInt8]] = [:] // "bank_patch" -> data
        private var currentBank: Int = 0
        private var currentPatch: Int = 0
        
        public init() {}
        
        public func loadPatches(from deviceID: UInt32) async throws {
            print("Loading patches from device \(deviceID)")
            
            // In real implementation, this would call SysExHandler.browsePatches
            // and store results in the patches dictionary
            
            // For now, simulate with some default data
            let bankPatchKey = "0_0"
            if let existingData = patches[bankPatchKey] {
                print("Loaded \(existingData.count) bytes for patch 0/0")
            }
        }
        
        public func savePatches(
            to deviceID: UInt32,
            bank: Int,
            patch: Int,
            data: [UInt8]
        ) async throws {
            let key = "\(bank)_\(patch)"
            patches[key] = data
            
            print("Saved \(data.count) bytes for patch \(bank)/\(patch)")
            
            // In real implementation, this would call SysExHandler.savePatch
        }
        
        public func getCurrentBank() -> Int { return currentBank }
        public func setCurrentBank(_ bank: Int) { currentBank = bank }
        
        public func getCurrentPatch() -> Int { return currentPatch }
        public func setCurrentPatch(_ patch: Int) { currentPatch = patch }
    }
}
