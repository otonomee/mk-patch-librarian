import XCTest
@testable import PBAPI

/// Chart §9 GLOBAL DATA DUMP (0x51) host -> synth: the synth stores the data
/// and answers §11 DATA LOAD COMPLETED (0x23) or §12 DATA LOAD ERROR (0x24).
final class GlobalWriteAckTests: XCTestCase {

    private func frame(_ command: UInt8, channel: UInt8 = 0) -> [UInt8] {
        [0xF0, 0x42, 0x30 | channel, 0x58, command, 0xF7]
    }

    func testDataLoadCompletedIsSuccess() throws {
        XCTAssertNoThrow(try KorgSysEx.dataLoadAck(frame(0x23)))
    }

    func testDataLoadErrorThrowsRejected() {
        XCTAssertThrowsError(try KorgSysEx.dataLoadAck(frame(0x24))) { error in
            XCTAssertEqual(error as? KorgSysExError, .dataLoadRejected)
        }
    }

    func testFormatErrorIsReportedAsDeviceError() {
        XCTAssertThrowsError(try KorgSysEx.dataLoadAck(frame(0x26))) { error in
            XCTAssertEqual(error as? KorgSysExError, .deviceReportedError(0x26))
        }
    }

    func testOtherRepliesAreUnexpected() {
        XCTAssertThrowsError(try KorgSysEx.dataLoadAck(frame(0x21))) { error in
            XCTAssertEqual(error as? KorgSysExError, .unexpectedReply(expected: 0x23, got: 0x21))
        }
    }

    /// The ack carries the synth's own global channel in the header; a
    /// non-channel-1 ack is still a valid ack.
    func testAckOnAnyChannelIsAccepted() {
        XCTAssertNoThrow(try KorgSysEx.dataLoadAck(frame(0x23, channel: 7)))
    }

    func testIsDataLoadReplyFiltersAckFramesOnly() {
        XCTAssertTrue(KorgSysEx.isDataLoadReply(frame(0x23)))
        XCTAssertTrue(KorgSysEx.isDataLoadReply(frame(0x24)))
        XCTAssertTrue(KorgSysEx.isDataLoadReply(frame(0x26)))
        XCTAssertFalse(KorgSysEx.isDataLoadReply(frame(0x21)))
        XCTAssertFalse(KorgSysEx.isDataLoadReply([0xF0, 0x7E, 0xF7]))
    }
}
