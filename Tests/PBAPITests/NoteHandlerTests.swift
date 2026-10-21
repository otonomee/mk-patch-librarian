import XCTest
@testable import PBAPI

/// NoteHandler: the audition keyboard's Note On/Off byte construction.
/// Only the pure message-building is tested here — actually sending goes
/// through real CoreMIDI, same as the rest of this module's send paths.
final class NoteHandlerTests: XCTestCase {

    func testNoteOnMessageShape() {
        let msg = PBAPI.NoteHandler.noteOnMessage(channel: 0, note: 60, velocity: 100)
        XCTAssertEqual(msg, [0x90, 60, 100])
    }

    func testNoteOnEncodesChannelInLowNibble() {
        // Channel 9 (MIDI channel 10) -> status byte 0x99.
        let msg = PBAPI.NoteHandler.noteOnMessage(channel: 9, note: 64, velocity: 127)
        XCTAssertEqual(msg[0], 0x99)
    }

    func testNoteOffMessageShapeAndZeroVelocity() {
        let msg = PBAPI.NoteHandler.noteOffMessage(channel: 0, note: 60)
        XCTAssertEqual(msg, [0x80, 60, 0])
    }

    func testNoteOnClampsChannelNoteAndVelocityToValidMidiRanges() {
        let msg = PBAPI.NoteHandler.noteOnMessage(channel: 99, note: 999, velocity: 0)
        XCTAssertEqual(msg[0] & 0x0F, 15) // channel clamped to 0...15
        XCTAssertEqual(msg[1], 127)       // note clamped to 0...127
        XCTAssertEqual(msg[2], 1)         // velocity clamped to 1...127 (0 would read as a note-off)
    }

    func testNoteOnClampsNegativeValues() {
        let msg = PBAPI.NoteHandler.noteOnMessage(channel: -5, note: -1, velocity: -1)
        XCTAssertEqual(msg[0] & 0x0F, 0)
        XCTAssertEqual(msg[1], 0)
        XCTAssertEqual(msg[2], 1)
    }

    func testEveryNoteOnStatusByteHasHighNibble0x9() {
        for ch in 0...15 {
            let msg = PBAPI.NoteHandler.noteOnMessage(channel: ch, note: 60)
            XCTAssertEqual(msg[0] & 0xF0, 0x90)
        }
    }

    func testEveryNoteOffStatusByteHasHighNibble0x8() {
        for ch in 0...15 {
            let msg = PBAPI.NoteHandler.noteOffMessage(channel: ch, note: 60)
            XCTAssertEqual(msg[0] & 0xF0, 0x80)
        }
    }
}
