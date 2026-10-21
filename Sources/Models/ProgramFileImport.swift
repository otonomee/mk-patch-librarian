import Foundation
import PBAPI

/// Errors that can occur while importing microKORG program data from files.
public enum ProgramImportError: Error, LocalizedError {
    case noSysExFramesFound
    case unsupportedCommand(UInt8)
    case programDataSizeMismatch(expected: Int, got: Int)
    case bankDataSizeMismatch(expected: Int, got: Int)

    public var errorDescription: String? {
        switch self {
        case .noSysExFramesFound:
            return "No SysEx frames found in file"
        case .unsupportedCommand(let cmd):
            return String(format: "Unsupported SysEx command 0x%02X", cmd)
        case .programDataSizeMismatch(let expected, let got):
            return "Program data size mismatch: expected \(expected), got \(got)"
        case .bankDataSizeMismatch(let expected, let got):
            return "Bank data size mismatch: expected \(expected), got \(got)"
        }
    }
}

/// Import microKORG programs from raw SysEx data.
///
/// Supported sources:
/// - A single 0x40 CURRENT PROGRAM DATA dump (e.g. a `.prg` file from a
///   SoundEditor export) → one program.
/// - A 0x4C PROGRAM DATA dump → one program.
/// - A 0x50 ALL DATA dump (e.g. a `.set` file) → 128 programs.
public enum ProgramFileImport {

    /// One imported program with its inferred slot/name.
    public struct ImportedProgram: Identifiable {
        public let id = UUID()
        /// Index inside the source file (0 for a single program dump,
        /// 0...127 for a bank dump). Only meaningful when
        /// `hasKnownSourcePosition` is true — a standalone single-program
        /// dump (e.g. a `.prg` file) always has `sourceIndex == 0` as a
        /// placeholder, not a real original slot.
        public let sourceIndex: Int
        /// True only for a program pulled out of a `.set`/full-bank dump,
        /// where `sourceIndex` is a real original slot position. False for
        /// a standalone single-program dump, where `sourceIndex` is just
        /// 0 with no slot behind it — importing several separate `.prg`
        /// files at once would otherwise show every one of them labeled
        /// with the same fake "A.11"-style slot.
        public let hasKnownSourcePosition: Bool
        /// Parsed program model.
        public let program: MicroKORGProgram

        public init(sourceIndex: Int, hasKnownSourcePosition: Bool, program: MicroKORGProgram) {
            self.sourceIndex = sourceIndex
            self.hasKnownSourcePosition = hasKnownSourcePosition
            self.program = program
        }

        /// Display name from the program bytes.
        public var name: String {
            KorgSysEx.programName(from: program.data)
        }
    }

    /// Parse raw bytes that may contain one or more SysEx frames.
    public static func programs(from data: [UInt8]) throws -> [ImportedProgram] {
        let frames = extractSysExFrames(from: data)
        guard !frames.isEmpty else { throw ProgramImportError.noSysExFramesFound }

        var imported: [ImportedProgram] = []
        for frame in frames {
            let parsed = try KorgSysEx.parse(frame)
            switch parsed.command {
            case .currentProgramDump:
                guard parsed.data.count == KorgSysEx.programDataSize else {
                    throw ProgramImportError.programDataSizeMismatch(
                        expected: KorgSysEx.programDataSize,
                        got: parsed.data.count
                    )
                }
                guard let program = MicroKORGProgram(data: parsed.data) else {
                    throw ProgramImportError.programDataSizeMismatch(
                        expected: KorgSysEx.programDataSize,
                        got: parsed.data.count
                    )
                }
                imported.append(ImportedProgram(sourceIndex: 0, hasKnownSourcePosition: false, program: program))

            case .programDump:
                // A 0x4C dump is bank-sized in the current framing; treat it
                // as a bank of one if it happens to be 254 bytes, otherwise
                // skip. In practice `.prg` files use 0x40, so this is rare.
                if parsed.data.count == KorgSysEx.programDataSize,
                   let program = MicroKORGProgram(data: parsed.data) {
                    imported.append(ImportedProgram(sourceIndex: 0, hasKnownSourcePosition: false, program: program))
                }

            case .allDataDump:
                let bank = try KorgSysEx.bank(fromAllData: parsed.data)
                guard bank.count == KorgSysEx.bankDataSize else {
                    throw ProgramImportError.bankDataSizeMismatch(
                        expected: KorgSysEx.bankDataSize,
                        got: bank.count
                    )
                }
                for index in 0..<KorgSysEx.programsPerBank {
                    let start = index * KorgSysEx.programDataSize
                    let slice = Array(bank[start..<(start + KorgSysEx.programDataSize)])
                    guard let program = MicroKORGProgram(data: slice) else {
                        throw ProgramImportError.programDataSizeMismatch(
                            expected: KorgSysEx.programDataSize,
                            got: slice.count
                        )
                    }
                    imported.append(ImportedProgram(sourceIndex: index, hasKnownSourcePosition: true, program: program))
                }

            default:
                throw ProgramImportError.unsupportedCommand(parsed.command.rawValue)
            }
        }
        return imported
    }

    /// Extract complete SysEx frames (F0 ... F7) from arbitrary bytes.
    ///
    /// Handles both raw SysEx frames and Standard MIDI File (SMF) SysEx
    /// wrapper events. SMF wraps SysEx as `F0 <VLQ-length> <payload> F7`;
    /// raw SysEx is already `F0 <payload including F7>`. The first payload
    /// byte distinguishes them: Korg's manufacturer ID is 0x42 (< 0x80), while
    /// a VLQ length byte is always >= 0x80.
    public static func extractSysExFrames(from data: [UInt8]) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        var index = 0
        while index < data.count {
            guard data[index] == KorgSysEx.sysExStart else {
                index += 1
                continue
            }
            let start = index
            index += 1
            guard index < data.count else { break }

            let nextByte = data[index]
            if nextByte & 0x80 == 0 {
                // Raw SysEx: next byte is the manufacturer ID (Korg = 0x42).
                // The frame ends at the next F7.
                while index < data.count && data[index] != KorgSysEx.sysExEnd {
                    index += 1
                }
                if index < data.count {
                    index += 1
                }
                frames.append(Array(data[start..<index]))
            } else {
                // SMF SysEx wrapper: read VLQ length, then that many payload
                // bytes. The payload is the real SysEx event (which already
                // ends with F7).
                var length = 0
                while index < data.count {
                    let b = data[index]
                    index += 1
                    length = (length << 7) | Int(b & 0x7F)
                    if b & 0x80 == 0 { break }
                }
                let payloadStart = index
                let payloadEnd = min(payloadStart + length, data.count)
                let payload = Array(data[payloadStart..<payloadEnd])
                // Rebuild a clean F0 ... F7 frame from the payload.
                var clean: [UInt8] = [KorgSysEx.sysExStart]
                clean.append(contentsOf: payload)
                if clean.last != KorgSysEx.sysExEnd, payloadEnd < data.count,
                   data[payloadEnd] == KorgSysEx.sysExEnd {
                    clean.append(KorgSysEx.sysExEnd)
                }
                frames.append(clean)
                index = payloadEnd
            }
        }
        return frames
    }
}
