import Foundation

// MARK: - Korg SysEx framing (MicroKORG / MS2000 family)
//
// PRIMARY REFERENCE: microKORG S MIDI Implementation rev 1.01 (docs/
// microkorg-s-midi-implementation-2026.txt). It documents a NEW dialect
// (header `F0 42 3n 00 01 40`, 256 programs, two-byte program numbers,
// per-parameter 0x41) — see HANDOFF-v12.md §2.1. This file speaks the
// LEGACY dialect (model ID 0x58, 128 programs), which the S still accepts
// and which is what every live measurement here was made with. The two
// dialects agree on all function codes and data formats; they differ in
// the header ID, the program-number width in 0x11/0x1C, and bank size.
//
// Verified against reference dumps of the microKORG's own factory data:
//
//   voice   297 B file -> header F0 42 30 58 40 | 291 encoded | F7 -> 254 decoded
//   bank  37163 B file -> header F0 42 30 58 4C | 37157 encoded | F7 -> 32512 decoded
//   global  235 B file -> header F0 42 30 58 51 | 229 encoded | F7 -> 200 decoded
//
// 32512 == 128 * 254 exactly, with zero remainder, and program names appear at a
// clean 254-byte stride. A bank is therefore ONE continuous encoded stream, not
// 128 individually-framed programs.
//
// IMPORTANT: the body is 7-to-8 bit packed. Korg transmits 7 data bytes as 8 MIDI
// bytes: a leading MSB byte holding the high bit of each of the following 7, then
// those 7 bytes with their high bits cleared (MIDI data bytes must be <= 0x7F).
// Because ASCII is 7-bit, the MSB bytes covering a program name are always 0x00,
// which makes an undecoded buffer *look* like it contains clean text at a tidy
// offset. That coincidence is why earlier notes recorded a "6-byte header" and a
// "290-byte payload" -- the 6th byte was really the first MSB byte of the body.
// All parameter offsets below index the DECODED buffer.

public enum KorgSysEx {

    // MARK: Framing constants

    public static let sysExStart: UInt8 = 0xF0
    public static let sysExEnd: UInt8 = 0xF7

    /// Korg manufacturer ID.
    public static let korgID: UInt8 = 0x42
    /// MicroKORG model ID.
    public static let microkorgID: UInt8 = 0x58

    /// Format byte is 0x30 | channel, where channel is 0-15 (MIDI channel 1-16).
    /// Hardcoded to channel 1 (n = 0) for now; the reference dumps all show 0x30.
    public static let channel: UInt8 = 0x00

    // MARK: Sizes (decoded)

    /// One program / voice, decoded. Matches the documented MS2000 program size.
    public static let programDataSize = 254
    public static let programsPerBank = 128
    /// 128 * 254 == 32512, confirmed exactly against the bank dump.
    public static let bankDataSize = programsPerBank * programDataSize
    public static let globalDataSize = 200
    /// A 0x50 ALL DATA dump = every program + global settings, measured at
    /// 32712 decoded bytes on the microKORG S (and per chart NOTE 4 for OG).
    public static let allDataSize = bankDataSize + globalDataSize
    /// Program name is 12 ASCII bytes, space padded, at the start of a program.
    public static let nameLength = 12

    // MARK: Commands

    /// Korg splits requests from dumps. Sending a dump opcode does NOT ask the
    /// synth for data -- it tells the synth to accept data. To pull a patch you
    /// send the matching *request* and the synth replies with the dump:
    ///
    ///   currentProgramDumpRequest (0x10) -> currentProgramDump (0x40)
    ///   programDumpRequest        (0x1C) -> programDump        (0x4C)
    ///   allDataDumpRequest        (0x0F) -> allDataDump        (0x50)
    ///   globalDumpRequest         (0x0E) -> globalDump         (0x51)
    public enum Command: UInt8, CaseIterable, Sendable {

        // Host -> synth, requests.
        case currentProgramDumpRequest = 0x10
        case programWriteRequest       = 0x11
        case programDumpRequest        = 0x1C
        case allDataDumpRequest        = 0x0F
        case globalDumpRequest         = 0x0E

        // Dumps. Synth -> host as a reply, or host -> synth to write.
        case currentProgramDump = 0x40
        case programDump        = 0x4C
        case allDataDump        = 0x50
        case globalDump         = 0x51

        // Synth -> host, acknowledgements.
        case writeCompleted    = 0x21
        case writeError        = 0x22
        case dataLoadCompleted = 0x23
        case dataLoadError     = 0x24
        /// Chart §10 RECEIVE DATA FORMAT ERROR — measured live on the S:
        /// an addressed 0x1C gets `F0 42 3g 58 26 F7` back.
        case dataFormatError   = 0x26

        public var isDump: Bool {
            switch self {
            case .currentProgramDump, .programDump, .allDataDump, .globalDump: return true
            default: return false
            }
        }

        /// Expected decoded byte count for a dump, or nil if not a dump.
        public var expectedDataSize: Int? {
            switch self {
            case .currentProgramDump: return programDataSize
            case .programDump:        return bankDataSize
            case .allDataDump:        return allDataSize
            case .globalDump:         return globalDataSize
            default:                  return nil
            }
        }

        public var isError: Bool {
            self == .writeError || self == .dataLoadError || self == .dataFormatError
        }
    }

    // MARK: Header

    /// `F0 42 3n 58 <cmd>` -- five bytes. The reference dumps show 0x30 because
    /// they were captured on MIDI channel 1.
    public static func header(for command: Command) -> [UInt8] {
        [sysExStart, korgID, 0x30 | (channel & 0x0F), microkorgID, command.rawValue]
    }

    // MARK: Message construction

    /// Build a complete SysEx message, 7-to-8 encoding `data` if present.
    public static func message(_ command: Command, data: [UInt8] = []) -> [UInt8] {
        var out = header(for: command)
        if !data.isEmpty {
            out.append(contentsOf: encode7to8(data))
        }
        out.append(sysExEnd)
        return out
    }

    /// Ask the synth for the patch currently in the edit buffer.
    public static func requestCurrentProgram() -> [UInt8] {
        message(.currentProgramDumpRequest)
    }

    /// Ask the synth for all 128 programs via the classic 0x1C request.
    ///
    /// NOTE: the microKORG S does NOT honor this for a full bank — it answers
    /// a bare 0x1C with a single address-prefixed program and rejects addressed
    /// variants with a 0x26 format error. Use `requestAllData()` to load banks.
    public static func requestBank() -> [UInt8] {
        message(.programDumpRequest)
    }

    /// Ask the synth for every program + global settings in one dump (0x0F -> 0x50).
    ///
    /// Verified live on the microKORG S: one 37392-byte frame decoding to
    /// 32712 bytes (32512 bank + 200 global), first program "Pump Stab".
    public static func requestAllData() -> [UInt8] {
        message(.allDataDumpRequest)
    }

    /// Ask the synth for its global settings.
    public static func requestGlobal() -> [UInt8] {
        message(.globalDumpRequest)
    }

    /// Send a 254-byte program into the synth's edit buffer (audible immediately,
    /// not yet written to a slot).
    public static func sendCurrentProgram(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count == programDataSize else {
            throw KorgSysExError.wrongDataSize(expected: programDataSize, got: data.count)
        }
        return message(.currentProgramDump, data: data)
    }

    /// Commit the edit buffer to a concrete slot (chart §5):
    /// `F0 42 3g 58 11 00 pp F7` — fixed 0x00, then destination 0...127.
    /// Passing nil keeps the legacy bodyless form (synth-side selection).
    public static func writeCurrentProgram(to programIndex: Int? = nil) -> [UInt8] {
        guard let index = programIndex else { return message(.programWriteRequest) }
        var out = header(for: .programWriteRequest)
        out.append(0x00)
        out.append(UInt8(max(0, min(127, index))))
        out.append(sysExEnd)
        return out
    }

    /// Classify the synth's reply to a `0x11` PROGRAM WRITE REQUEST.
    ///
    /// Chart §5: the synth answers with §13 WRITE COMPLETED (`0x21`) on
    /// success or §14 WRITE ERROR (`0x22`) when the write did not happen
    /// (Protect on, invalid destination...). Both frames are bodyless
    /// (`F0 42 3g 58 <cmd> F7`). Returns the ack command on success;
    /// throws `writeRejected` for `0x22`, `unexpectedReply` for anything
    /// else (e.g. `0x26` FORMAT ERROR).
    @discardableResult
    public static func writeAck(_ reply: [UInt8]) throws -> Command {
        let parsed = try parse(reply)
        switch parsed.command {
        case .writeCompleted:
            return .writeCompleted
        case .writeError:
            throw KorgSysExError.writeRejected
        default:
            throw KorgSysExError.unexpectedReply(
                expected: Command.writeCompleted.rawValue,
                got: parsed.command.rawValue
            )
        }
    }

    /// True for the bodyless `0x23`/`0x24` DATA LOAD acks the synth sends
    /// after a `0x40` edit-buffer load (chart §6/§11/§12). The editor's save
    /// flow sends `0x40` then `0x11` back-to-back, so the load's ack can
    /// arrive while the write's ack is being awaited — measured live: it was
    /// mistaken for the write's reply ("Expected 0x21 from device, got 0x23").
    public static func isLoadAck(_ frame: [UInt8]) -> Bool {
        guard frame.count >= 5 else { return false }
        return frame[4] == 0x23 || frame[4] == 0x24
    }

    /// Classify the synth's reply to a host -> synth dump (e.g. `0x51`
    /// GLOBAL DATA DUMP): chart §11 DATA LOAD COMPLETED (`0x23`) on success,
    /// §12 DATA LOAD ERROR (`0x24`) when it was not stored, §10 FORMAT ERROR
    /// (`0x26`) for a malformed message.
    public static func dataLoadAck(_ reply: [UInt8]) throws {
        let parsed = try parse(reply)
        switch parsed.command {
        case .dataLoadCompleted:
            return
        case .dataLoadError:
            throw KorgSysExError.dataLoadRejected
        case .dataFormatError:
            throw KorgSysExError.deviceReportedError(parsed.command.rawValue)
        default:
            throw KorgSysExError.unexpectedReply(
                expected: Command.dataLoadCompleted.rawValue,
                got: parsed.command.rawValue
            )
        }
    }

    /// True for frames that can answer a dump write (`0x23`/`0x24`/`0x26`).
    public static func isDataLoadReply(_ frame: [UInt8]) -> Bool {
        guard frame.count >= 6, frame[0] == sysExStart, frame[1] == korgID else { return false }
        return frame[4] == 0x23 || frame[4] == 0x24 || frame[4] == 0x26
    }

    /// Send a full 32512-byte bank.
    public static func sendBank(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count == bankDataSize else {
            throw KorgSysExError.wrongDataSize(expected: bankDataSize, got: data.count)
        }
        return message(.programDump, data: data)
    }

    /// Send the 200-byte global settings.
    public static func sendGlobal(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count == globalDataSize else {
            throw KorgSysExError.wrongDataSize(expected: globalDataSize, got: data.count)
        }
        return message(.globalDump, data: data)
    }

    // MARK: Parsing

    public struct Parsed: Sendable {
        public let command: Command
        /// Decoded (8-bit) body. Empty for requests and acknowledgements.
        public let data: [UInt8]

        public init(command: Command, data: [UInt8]) {
            self.command = command
            self.data = data
        }
    }

    /// Validate and decode an inbound SysEx message.
    public static func parse(_ message: [UInt8]) throws -> Parsed {
        guard message.count >= 6 else {
            throw KorgSysExError.tooShort(message.count)
        }
        guard message.first == sysExStart, message.last == sysExEnd else {
            throw KorgSysExError.notSysEx
        }
        guard message[1] == korgID else {
            throw KorgSysExError.wrongManufacturer(message[1])
        }
        guard message[2] & 0xF0 == 0x30 else {
            throw KorgSysExError.malformedHeader
        }
        guard message[3] == microkorgID else {
            throw KorgSysExError.wrongModel(message[3])
        }
        guard let command = Command(rawValue: message[4]) else {
            throw KorgSysExError.unknownCommand(message[4])
        }

        let body = Array(message[5..<(message.count - 1)])
        let data = body.isEmpty ? [] : decode8to7(body)

        if let expected = command.expectedDataSize, data.count != expected {
            throw KorgSysExError.wrongDataSize(expected: expected, got: data.count)
        }
        return Parsed(command: command, data: data)
    }

    // MARK: 7-to-8 bit codec

    /// Pack 8-bit data for MIDI: each group of 7 bytes is emitted as a leading
    /// MSB byte followed by those 7 bytes with bit 7 cleared. A short final group
    /// is emitted as-is (MSB byte + however many bytes remain).
    public static func encode7to8(_ raw: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity((raw.count / 7 + 1) * 8)

        var index = 0
        while index < raw.count {
            let group = raw[index..<min(index + 7, raw.count)]
            var msb: UInt8 = 0
            for (offset, byte) in group.enumerated() where byte & 0x80 != 0 {
                msb |= 1 << UInt8(offset)
            }
            out.append(msb)
            out.append(contentsOf: group.map { $0 & 0x7F })
            index += 7
        }
        return out
    }

    /// Inverse of `encode7to8`.
    public static func decode8to7(_ encoded: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(encoded.count / 8 * 7 + 7)

        var index = 0
        while index < encoded.count {
            let msb = encoded[index]
            let group = encoded[(index + 1)..<min(index + 8, encoded.count)]
            for (offset, byte) in group.enumerated() {
                let high: UInt8 = (msb >> UInt8(offset)) & 1 == 1 ? 0x80 : 0
                out.append((byte & 0x7F) | high)
            }
            index += 8
        }
        return out
    }

    // MARK: Program names

    /// Read the 12-byte ASCII name from the start of a decoded program.
    public static func programName(from program: ArraySlice<UInt8>) -> String {
        let bytes = program.prefix(nameLength).map { byte -> UInt8 in
            // Guard against control bytes so a corrupt dump cannot emit junk.
            (byte >= 0x20 && byte < 0x7F) ? byte : 0x20
        }
        return String(bytes: bytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    public static func programName(from program: [UInt8]) -> String {
        programName(from: program[...])
    }

    /// Write a 12-byte ASCII name, space padded and truncated, into a program.
    public static func setProgramName(_ name: String, in program: inout [UInt8]) {
        guard program.count >= nameLength else { return }
        let ascii = name.unicodeScalars
            .filter { $0.value >= 0x20 && $0.value < 0x7F }
            .map { UInt8($0.value) }
        let padded = Array((ascii + [UInt8](repeating: 0x20, count: nameLength)).prefix(nameLength))
        program.replaceSubrange(0..<nameLength, with: padded)
    }

    // MARK: Bank helpers

    /// The 128-program bank out of a decoded 0x50 ALL DATA dump (which also
    /// carries the 200-byte global settings as its tail).
    public static func bank(fromAllData data: [UInt8]) throws -> [UInt8] {
        guard data.count == allDataSize else {
            throw KorgSysExError.wrongDataSize(expected: allDataSize, got: data.count)
        }
        return Array(data.prefix(bankDataSize))
    }

    /// Slice one program out of a decoded 32512-byte bank.
    public static func program(_ index: Int, inBank bank: [UInt8]) throws -> [UInt8] {
        guard bank.count == bankDataSize else {
            throw KorgSysExError.wrongDataSize(expected: bankDataSize, got: bank.count)
        }
        guard (0..<programsPerBank).contains(index) else {
            throw KorgSysExError.programIndexOutOfRange(index)
        }
        let start = index * programDataSize
        return Array(bank[start..<(start + programDataSize)])
    }

    /// All 128 program names from a decoded bank.
    public static func programNames(inBank bank: [UInt8]) throws -> [String] {
        guard bank.count == bankDataSize else {
            throw KorgSysExError.wrongDataSize(expected: bankDataSize, got: bank.count)
        }
        return (0..<programsPerBank).map { index in
            let start = index * programDataSize
            return programName(from: bank[start..<(start + nameLength)])
        }
    }
}

// MARK: - Errors

public enum KorgSysExError: LocalizedError, Equatable {
    case notSysEx
    case tooShort(Int)
    case malformedHeader
    case wrongManufacturer(UInt8)
    case wrongModel(UInt8)
    case unknownCommand(UInt8)
    case wrongDataSize(expected: Int, got: Int)
    case programIndexOutOfRange(Int)
    case unexpectedReply(expected: UInt8, got: UInt8)
    case deviceReportedError(UInt8)
    /// Synth answered a 0x11 write with 0x22 WRITE ERROR.
    case writeRejected
    /// No 0x21/0x22 frame arrived before the deadline after a 0x11 write.
    case writeAckTimeout
    /// Synth answered a dump write with 0x24 DATA LOAD ERROR.
    case dataLoadRejected
    /// No 0x23/0x24 frame arrived before the deadline after a dump write.
    case dataLoadAckTimeout

    public var errorDescription: String? {
        switch self {
        case .notSysEx:
            return "Message is not a SysEx message (missing F0/F7)"
        case .tooShort(let count):
            return "SysEx message too short: \(count) bytes"
        case .malformedHeader:
            return "Malformed Korg header: format byte is not 0x3n"
        case .wrongManufacturer(let id):
            return String(format: "Not a Korg message (manufacturer 0x%02X, expected 0x42)", id)
        case .wrongModel(let id):
            return String(format: "Not a MicroKORG message (model 0x%02X, expected 0x58)", id)
        case .unknownCommand(let id):
            return String(format: "Unrecognized Korg command byte 0x%02X", id)
        case .wrongDataSize(let expected, let got):
            return "Wrong data size: expected \(expected) bytes, got \(got)"
        case .programIndexOutOfRange(let index):
            return "Program index \(index) out of range 0-127"
        case .unexpectedReply(let expected, let got):
            return String(format: "Expected command 0x%02X from device, got 0x%02X", expected, got)
        case .deviceReportedError(let code):
            return String(format: "Device reported an error (command 0x%02X)", code)
        case .writeRejected:
            return "Synth rejected the write (WRITE ERROR 0x22) — check that Protect is off"
        case .writeAckTimeout:
            return "No write acknowledgement (0x21/0x22) received — the write is not confirmed"
        case .dataLoadRejected:
            return "Synth rejected the data (DATA LOAD ERROR 0x24)"
        case .dataLoadAckTimeout:
            return "No acknowledgement (0x23/0x24) received — the save is not confirmed"
        }
    }
}
