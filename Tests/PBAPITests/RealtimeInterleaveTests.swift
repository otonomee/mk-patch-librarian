import XCTest
@testable import PBAPI

/// Regression tests for system real-time bytes interleaved into a SysEx stream.
///
/// Found on real hardware (2026-10-15): the MicroKORG's MIDI clock (0xF8)
/// arrives *inside* the program-dump message. Without stripping, the reply is
/// 4-5 bytes too long (301 instead of 297), 7-to-8 decoding returns 258
/// instead of 254, and the dump is rejected.
final class RealtimeInterleaveTests: XCTestCase {

    // MARK: stripRealtime

    func testStripRealtimeRemovesClockAndSensing() {
        let input: [UInt8] = [0xF0, 0x42, 0x30, 0x58, 0x40, 0xF8, 0x7F, 0xFE, 0x00, 0xF7]
        XCTAssertEqual(MIDIOutputPort.stripRealtime(input),
                       [0xF0, 0x42, 0x30, 0x58, 0x40, 0x7F, 0x00, 0xF7],
                       "Real-time bytes (F8-FF) must be dropped; F0/F7 and payload survive")
    }

    func testStripRealtimeKeepsDataAndChannelStatus() {
        // Payload bytes are 7-bit; channel voice messages (80-EF) are < F8.
        let input: [UInt8] = [0x90, 0x40, 0x7F, 0x00, 0x7F]
        XCTAssertEqual(MIDIOutputPort.stripRealtime(input), input)
    }

    func testStripRealtimeOfEmptyInput() {
        XCTAssertEqual(MIDIOutputPort.stripRealtime([]), [])
    }

    // MARK: End-to-end framing

    /// A full current-program dump with clock bytes spliced in at every group
    /// boundary must still parse to exactly the original 254 bytes.
    func testInterleavedClockStillParsesTo254Bytes() throws {
        var program = [UInt8](repeating: 0x40, count: KorgSysEx.programDataSize)
        KorgSysEx.setProgramName("NewWave Bass", in: &program)

        let wire = KorgSysEx.message(.currentProgramDump, data: program)
        XCTAssertEqual(wire.count, 297, "5 header + 291 encoded + F7")

        // Splice 0xF8 clock bytes throughout, as the synth does.
        var interleaved: [UInt8] = []
        for (i, byte) in wire.enumerated() {
            interleaved.append(byte)
            if i % 16 == 7 { interleaved.append(0xF8) }
        }
        XCTAssertGreaterThan(interleaved.count, wire.count)

        let cleaned = MIDIOutputPort.stripRealtime(interleaved)
        XCTAssertEqual(cleaned, wire, "Stripping real-time bytes must restore the exact frame")

        let parsed = try KorgSysEx.parse(cleaned)
        XCTAssertEqual(parsed.command, .currentProgramDump)
        XCTAssertEqual(parsed.data.count, 254)
        XCTAssertEqual(KorgSysEx.programName(from: parsed.data), "NewWave Bass")
    }

    /// The captured hardware reply shape: 291-byte body with 4 clock bytes
    /// embedded, which previously decoded to 258 and was rejected.
    func testCapturedHardwareShapeDecodesTo254() throws {
        var program = [UInt8](repeating: 0x40, count: KorgSysEx.programDataSize)
        KorgSysEx.setProgramName("TEST PATCH 01", in: &program)
        var wire = KorgSysEx.message(.currentProgramDump, data: program)
        XCTAssertEqual(wire.count, 297)

        // Insert 4 F8 bytes at offsets matching the observed capture.
        for offset in [70, 131, 192, 253] {
            wire.insert(0xF8, at: offset)
        }
        XCTAssertEqual(wire.count, 301, "matches the captured smoke-reply.syx length")

        let parsed = try KorgSysEx.parse(MIDIOutputPort.stripRealtime(wire))
        XCTAssertEqual(parsed.data.count, 254)
    }
}
