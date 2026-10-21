import XCTest
@testable import PBAPI

/// Regression tests for the Korg SysEx framing and the 7-to-8 bit codec.
///
/// The `referenceDumps` tests read local Korg factory `.syx` dumps and are
/// skipped unless `MKSE_REFERENCE_DUMPS_DIR` points at a directory containing
/// them, so the suite still passes on a clean machine. Everything else is
/// self-contained.
final class KorgSysExTests: XCTestCase {

    // MARK: Header framing

    func testHeaderIsFiveBytes() {
        let header = KorgSysEx.header(for: .currentProgramDump)
        XCTAssertEqual(header, [0xF0, 0x42, 0x30, 0x58, 0x40],
                       "Header must be F0 42 3n 58 <cmd>, five bytes. A sixth byte " +
                       "would be the first MSB byte of the body, not header.")
    }

    func testRequestOpcodesAreNotDumpOpcodes() {
        // Sending 0x40 does not fetch a patch; it tells the synth to receive one.
        XCTAssertEqual(KorgSysEx.requestCurrentProgram()[4], 0x10)
        XCTAssertEqual(KorgSysEx.requestBank()[4], 0x1C)
        XCTAssertEqual(KorgSysEx.requestGlobal()[4], 0x0E)
    }

    func testRequestsAreBodylessAndTerminated() {
        for request in [KorgSysEx.requestCurrentProgram(),
                        KorgSysEx.requestBank(),
                        KorgSysEx.requestGlobal()] {
            XCTAssertEqual(request.count, 6, "request = 5-byte header + F7")
            XCTAssertEqual(request.last, 0xF7)
        }
    }

    func testWriteRequestTargetsExplicitSlot() {
        // Chart §5: 11 00 pp — fixed 0x00 then destination 0...127.
        XCTAssertEqual(KorgSysEx.writeCurrentProgram(to: 0),
                       [0xF0, 0x42, 0x30, 0x58, 0x11, 0x00, 0x00, 0xF7])
        XCTAssertEqual(KorgSysEx.writeCurrentProgram(to: 65),
                       [0xF0, 0x42, 0x30, 0x58, 0x11, 0x00, 0x41, 0xF7])
        XCTAssertEqual(Array(KorgSysEx.writeCurrentProgram(to: 999).suffix(3)),
                       [0x00, 0x7F, 0xF7], "index clamps to 127")
        // Legacy bodyless form (synth's own selection) still available.
        XCTAssertEqual(KorgSysEx.writeCurrentProgram(),
                       [0xF0, 0x42, 0x30, 0x58, 0x11, 0xF7])
    }

    // MARK: Write acknowledgement (0x11 -> 0x21 / 0x22)

    /// Chart §13: the synth answers a write with `F0 42 3g 58 21 F7`.
    func testWriteAckAcceptsCompletedFrame() throws {
        let ack = try KorgSysEx.writeAck([0xF0, 0x42, 0x30, 0x58, 0x21, 0xF7])
        XCTAssertEqual(ack, .writeCompleted)
    }

    /// Tolerate a stray body byte: decoding `[0x00]` yields no data, so an
    /// ack with padding must not be rejected as malformed.
    func testWriteAckToleratesPaddedBody() throws {
        let ack = try KorgSysEx.writeAck([0xF0, 0x42, 0x30, 0x58, 0x21, 0x00, 0xF7])
        XCTAssertEqual(ack, .writeCompleted)
    }

    /// Chart §14: `0x22` = write did NOT complete (Protect, bad slot...).
    /// This is the whole point of reading the ack — it must surface as a
    /// distinct, user-readable failure, not a generic one.
    func testWriteAckMapsWriteErrorToRejected() {
        let frame: [UInt8] = [0xF0, 0x42, 0x30, 0x58, 0x22, 0xF7]
        XCTAssertThrowsError(try KorgSysEx.writeAck(frame)) { error in
            XCTAssertEqual(error as? KorgSysExError, .writeRejected)
            XCTAssertEqual(
                (error as? KorgSysExError)?.errorDescription,
                "Synth rejected the write (WRITE ERROR 0x22) — check that Protect is off"
            )
        }
    }

    /// Any other reply is not an ack: 0x26 FORMAT ERROR (chart §10), 0x24
    /// NAK, an echoed request, or a well-formed dump the synth sent for its
    /// own reasons.
    func testWriteAckRejectsUnexpectedReplies() {
        for cmd: UInt8 in [0x26, 0x24, 0x10] {
            let frame = [0xF0, 0x42, 0x30, 0x58, cmd, 0xF7]
            XCTAssertThrowsError(try KorgSysEx.writeAck(frame)) { error in
                XCTAssertEqual(error as? KorgSysExError,
                               .unexpectedReply(expected: 0x21, got: cmd))
            }
        }
        // A dump is rejected too — but only after its own size checks pass,
        // so feed parse() a well-formed one.
        let dump = KorgSysEx.message(.currentProgramDump,
                                     data: [UInt8](repeating: 0x41, count: 254))
        XCTAssertThrowsError(try KorgSysEx.writeAck(dump)) { error in
            XCTAssertEqual(error as? KorgSysExError,
                           .unexpectedReply(expected: 0x21, got: 0x40))
        }
    }

    /// Chart §10 0x26 is a modeled error command: parse must accept the
    /// frame (so `exchange` can route it via `isError` to
    /// deviceReportedError) instead of failing with "unknown command".
    func testDataFormatErrorIsModeledAsAnErrorCommand() throws {
        XCTAssertTrue(KorgSysEx.Command.dataFormatError.isError)
        XCTAssertNil(KorgSysEx.Command.dataFormatError.expectedDataSize)
        let frame = KorgSysEx.header(for: .dataFormatError) + [0xF7]
        XCTAssertEqual(try KorgSysEx.parse(frame).command, .dataFormatError)
    }

    func testWriteAckRejectsMalformedFrames() {
        XCTAssertThrowsError(try KorgSysEx.writeAck([]))
        XCTAssertThrowsError(
            try KorgSysEx.writeAck([0x00, 0x42, 0x30, 0x58, 0x21, 0xF7]),
            "not SysEx"
        )
    }

    func testWriteAckTimeoutHasActionableDescription() {
        XCTAssertEqual(
            KorgSysExError.writeAckTimeout.errorDescription,
            "No write acknowledgement (0x21/0x22) received — the write is not confirmed"
        )
    }

    /// The save flow sends 0x40 then 0x11 back-to-back; the 0x40's load ack
    /// (0x23, or 0x24 on failure) can arrive while the write's ack is being
    /// awaited and must be skipped, not treated as the write's reply
    /// (measured live: "Expected 0x21 from device, got 0x23").
    func testLoadAcksAreRecognizedForSkipping() {
        let frame: (UInt8) -> [UInt8] = { [0xF0, 0x42, 0x30, 0x58, $0, 0xF7] }
        XCTAssertTrue(KorgSysEx.isLoadAck(frame(0x23)), "DATA LOAD COMPLETED")
        XCTAssertTrue(KorgSysEx.isLoadAck(frame(0x24)), "DATA LOAD ERROR")
        XCTAssertFalse(KorgSysEx.isLoadAck(frame(0x21)), "write ack: never skip")
        XCTAssertFalse(KorgSysEx.isLoadAck(frame(0x22)), "write nack: never skip")
        XCTAssertFalse(KorgSysEx.isLoadAck(frame(0x26)))
        XCTAssertFalse(KorgSysEx.isLoadAck([0xF0, 0x42]), "too short to classify")
    }

    // MARK: Codec

    func testEncodeDecodeRoundTripsArbitraryData() {
        // Include values above 0x7F so the MSB packing actually does work, and a
        // length that is not a multiple of 7 to exercise the short final group.
        for length in [0, 1, 6, 7, 8, 13, 14, 254, 32512] {
            var raw: [UInt8] = []
            raw.reserveCapacity(length)
            var seed: UInt8 = 0
            for _ in 0..<length {
                raw.append(seed)
                seed = seed &+ 37
            }
            let decoded = KorgSysEx.decode8to7(KorgSysEx.encode7to8(raw))
            XCTAssertEqual(Array(decoded.prefix(length)), raw,
                           "round trip failed at length \(length)")
        }
    }

    func testEncodedOutputIsAllValidMIDIDataBytes() {
        let raw = (0...255).map { UInt8($0) }
        let encoded = KorgSysEx.encode7to8(raw)
        XCTAssertFalse(encoded.contains { $0 > 0x7F },
                       "every encoded byte must be <= 0x7F or it would be read as MIDI status")
    }

    func testHighBitsSurviveTheRoundTrip() {
        let raw: [UInt8] = [0xFF, 0x80, 0x7F, 0x00, 0xAA, 0x55, 0xF7, 0xF0]
        XCTAssertEqual(Array(KorgSysEx.decode8to7(KorgSysEx.encode7to8(raw)).prefix(raw.count)), raw)
    }

    func testEncodedSizesMatchTheRealDumps() {
        // 254 -> 291 and 32512 -> 37157 are the sizes observed in the shipped files.
        XCTAssertEqual(KorgSysEx.encode7to8([UInt8](repeating: 0, count: 254)).count, 291)
        XCTAssertEqual(KorgSysEx.encode7to8([UInt8](repeating: 0, count: 32512)).count, 37157)
        XCTAssertEqual(KorgSysEx.encode7to8([UInt8](repeating: 0, count: 200)).count, 229)
    }

    func testBankSizeIdentity() {
        XCTAssertEqual(KorgSysEx.bankDataSize, 32512)
        XCTAssertEqual(KorgSysEx.programsPerBank * KorgSysEx.programDataSize, 32512)
    }

    // MARK: Known-good vector

    /// First 22 bytes of the real `microkorg-voice.syx`, verified by hexdump.
    /// Decodes to the program name "Mkinit".
    func testKnownVectorDecodesToExpectedName() throws {
        let prefix: [UInt8] = [
            0xF0, 0x42, 0x30, 0x58, 0x40,       // header
            0x00,                                // MSB byte for the next 7
            0x4D, 0x6B, 0x69, 0x6E, 0x69, 0x74, 0x20, // "Mkinit "
            0x00,                                // MSB byte for the next 7
            0x20, 0x20, 0x20, 0x20, 0x20, 0x00, 0x00, // "     " + 2 param bytes
        ]
        let decoded = KorgSysEx.decode8to7(Array(prefix[5...]))
        XCTAssertEqual(KorgSysEx.programName(from: decoded), "Mkinit")
    }

    // MARK: Parsing

    func testParseRejectsRolandHeader() {
        // The header this project previously shipped. It must not be accepted.
        let roland: [UInt8] = [0xF0, 0x41, 0x12, 0x00, 0x00, 0xF7]
        XCTAssertThrowsError(try KorgSysEx.parse(roland)) { error in
            XCTAssertEqual(error as? KorgSysExError, .wrongManufacturer(0x41))
        }
    }

    func testParseRejectsTruncatedAndNonSysEx() {
        XCTAssertThrowsError(try KorgSysEx.parse([0xF0, 0x42]))
        XCTAssertThrowsError(try KorgSysEx.parse([0x90, 0x42, 0x30, 0x58, 0x40, 0xF7]))
    }

    func testParseRejectsWrongDataSize() {
        // A 0x40 dump carrying too little data must be caught, not silently used.
        let short = KorgSysEx.message(.currentProgramDump, data: [UInt8](repeating: 0, count: 10))
        XCTAssertThrowsError(try KorgSysEx.parse(short)) { error in
            XCTAssertEqual(error as? KorgSysExError, .wrongDataSize(expected: 254, got: 10))
        }
    }

    func testRoundTripThroughMessageAndParse() throws {
        var program = [UInt8](repeating: 0x40, count: KorgSysEx.programDataSize)
        KorgSysEx.setProgramName("Bass Lead", in: &program)

        let message = try KorgSysEx.sendCurrentProgram(program)
        let parsed = try KorgSysEx.parse(message)

        XCTAssertEqual(parsed.command, .currentProgramDump)
        XCTAssertEqual(parsed.data, program)
        XCTAssertEqual(KorgSysEx.programName(from: parsed.data), "Bass Lead")
    }

    // MARK: Names

    func testNamePaddingAndTruncation() {
        var program = [UInt8](repeating: 0, count: KorgSysEx.programDataSize)

        KorgSysEx.setProgramName("Hi", in: &program)
        XCTAssertEqual(Array(program[0..<12]), Array("Hi          ".utf8))
        XCTAssertEqual(KorgSysEx.programName(from: program), "Hi")

        KorgSysEx.setProgramName("ThisNameIsFarTooLong", in: &program)
        XCTAssertEqual(program[0..<12].count, 12)
        XCTAssertEqual(KorgSysEx.programName(from: program), "ThisNameIsFa")
    }

    func testSendRejectsWrongSizedProgram() {
        XCTAssertThrowsError(try KorgSysEx.sendCurrentProgram([0x00, 0x01]))
        XCTAssertThrowsError(try KorgSysEx.sendBank([0x00]))
    }

    // MARK: Reference dumps (skipped unless a local dump directory is configured)

    /// Set `MKSE_REFERENCE_DUMPS_DIR` to a local directory of Korg factory
    /// `.syx` dumps (`microkorg-voice.syx`, `microkorg-global.syx`, etc.) to
    /// run these; otherwise they skip so the suite still passes on a clean
    /// checkout.
    private func loadDump(_ name: String) throws -> [UInt8] {
        guard let dir = ProcessInfo.processInfo.environment["MKSE_REFERENCE_DUMPS_DIR"] else {
            throw XCTSkip("MKSE_REFERENCE_DUMPS_DIR not set; skipping reference-dump test")
        }
        let path = "\(dir)/\(name)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("\(name) not found under MKSE_REFERENCE_DUMPS_DIR; skipping")
        }
        return [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    func testReferenceVoiceDump() throws {
        let parsed = try KorgSysEx.parse(try loadDump("microkorg-voice.syx"))
        XCTAssertEqual(parsed.command, .currentProgramDump)
        XCTAssertEqual(parsed.data.count, 254)
        XCTAssertEqual(KorgSysEx.programName(from: parsed.data), "Mkinit")
    }

    func testReferenceGlobalDump() throws {
        let parsed = try KorgSysEx.parse(try loadDump("microkorg-global.syx"))
        XCTAssertEqual(parsed.command, .globalDump)
        XCTAssertEqual(parsed.data.count, 200)
    }

    func testReferenceBankDumpHas128Programs() throws {
        let parsed = try KorgSysEx.parse(try loadDump("microkorg-voice-bank.syx"))
        XCTAssertEqual(parsed.command, .programDump)
        XCTAssertEqual(parsed.data.count, 32512)

        let names = try KorgSysEx.programNames(inBank: parsed.data)
        XCTAssertEqual(names.count, 128)
        XCTAssertEqual(names.first, "Patch 1")
        XCTAssertEqual(names[64], "Patch 65")
        XCTAssertEqual(names.last, "Patch 128")
    }

    /// Re-encoding a decoded dump must reproduce the original file byte for byte.
    /// This is the strongest check that the codec is right.
    func testReferenceDumpsReEncodeExactly() throws {
        for name in ["microkorg-voice.syx", "microkorg-voice-bank.syx", "microkorg-global.syx"] {
            let original = try loadDump(name)
            let parsed = try KorgSysEx.parse(original)
            let reencoded = KorgSysEx.message(parsed.command, data: parsed.data)
            XCTAssertEqual(reencoded, original, "re-encode mismatch for \(name)")
        }
    }

    // MARK: ALL DATA dump (0x0F -> 0x50) — the microKORG S bank-load path

    func testAllDataRequestFraming() {
        XCTAssertEqual(KorgSysEx.requestAllData(), [0xF0, 0x42, 0x30, 0x58, 0x0F, 0xF7])
        XCTAssertEqual(KorgSysEx.Command.allDataDumpRequest.rawValue, 0x0F)
        XCTAssertEqual(KorgSysEx.Command.allDataDump.rawValue, 0x50)
        XCTAssertTrue(KorgSysEx.Command.allDataDump.isDump)
        XCTAssertFalse(KorgSysEx.Command.allDataDumpRequest.isDump)
        XCTAssertEqual(KorgSysEx.Command.allDataDump.expectedDataSize, KorgSysEx.allDataSize)
        XCTAssertEqual(KorgSysEx.allDataSize, 32712, "128 programs (32512) + global (200)")
    }

    func testAllDataDumpRoundTripAndBankSlice() {
        var raw: [UInt8] = []
        var seed: UInt8 = 11
        for _ in 0..<KorgSysEx.allDataSize {
            raw.append(seed)
            seed = seed &+ 29
        }

        let message = KorgSysEx.message(.allDataDump, data: raw)
        guard let parsed = try? KorgSysEx.parse(message) else {
            return XCTFail("0x50 dump must parse")
        }
        XCTAssertEqual(parsed.command, .allDataDump)
        XCTAssertEqual(parsed.data, raw)

        let bank = try? KorgSysEx.bank(fromAllData: parsed.data)
        XCTAssertEqual(bank?.count, KorgSysEx.bankDataSize)
        XCTAssertEqual(bank, Array(raw.prefix(KorgSysEx.bankDataSize)),
                       "the bank is the leading 32512 bytes; global rides the tail")
        XCTAssertThrowsError(try KorgSysEx.bank(fromAllData: Array(raw.prefix(32512)))) {
            XCTAssertEqual($0 as? KorgSysExError,
                           .wrongDataSize(expected: KorgSysEx.allDataSize, got: KorgSysEx.bankDataSize))
        }
    }

    /// Live microKORG S capture (SmokeTest --req "F0 42 30 58 0F F7") saved at the
    /// repo root — regression cover for the real hardware reply, skipped if absent.
    func testMicroKORGSAllDataCapture() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = repoRoot.appendingPathComponent("req-3-capture.syx").path
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("req-3-capture.syx not present; run SmokeTest --req on hardware")
        }
        let raw = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))

        // Frame-split, then parse WITHOUT the strict size gate of KorgSysEx.parse
        // is unnecessary here: a single well-formed frame is expected.
        var frames: [[UInt8]] = []
        var current: [UInt8] = []
        for byte in raw {
            if byte == 0xF0 { current = [0xF0] }
            else if byte == 0xF7 && !current.isEmpty {
                current.append(0xF7)
                frames.append(current)
                current = []
            } else if !current.isEmpty {
                current.append(byte)
            }
        }
        XCTAssertEqual(frames.count, 1, "the S answers 0x0F with one 0x50 frame")

        let parsed = try KorgSysEx.parse(frames[0])
        XCTAssertEqual(parsed.command, .allDataDump)
        XCTAssertEqual(parsed.data.count, 32712)

        let bank = try KorgSysEx.bank(fromAllData: parsed.data)
        let names = try KorgSysEx.programNames(inBank: bank)
        XCTAssertEqual(names.count, 128)
        XCTAssertEqual(names.first, "Pump Stab", "name observed in the live capture")
        XCTAssertFalse(names[1].isEmpty, "at least two distinct programs in an S bank")
    }
}
