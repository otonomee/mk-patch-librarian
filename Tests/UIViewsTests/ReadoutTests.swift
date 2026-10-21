import XCTest
@testable import UIViews

/// v15 §3.3 — chart-cited readout formatting.
///
/// Pins: the signed readout never shows −64 (chart *3-6 floors bytes 00 and
/// 01 at −63: `00,01~7F = -63,-63~+63`, docs/microkorg-s-midi-implementation-
/// 2026.txt line 135), values clamp to the slider's chart range, and Panpot
/// follows TABLE 2 +26 (`0~64~127 = L64~CNT~R63`).
final class ReadoutTests: XCTestCase {

    func testSignedNeverShowsMinus64AtTheChartFloor() {
        // signed64(byte 0) is -64; every 64±N table floors at -63.
        XCTAssertEqual(Readout.signed(-64, range: -63...63), "-63")
        XCTAssertEqual(Readout.signed(-63, range: -63...63), "-63")
    }

    func testSignedShowsExplicitSignAndUnit() {
        XCTAssertEqual(Readout.signed(12, range: -24...24, unit: "st"), "+12 st")
        XCTAssertEqual(Readout.signed(-3, range: -24...24, unit: "st"), "-3 st")
        XCTAssertEqual(Readout.signed(0, range: -24...24, unit: "st"), "0 st")
        XCTAssertEqual(Readout.signed(7, range: -63...63), "+7")
        XCTAssertEqual(Readout.signed(0, range: -63...63), "0")
    }

    func testSignedClampsOutOfRangeBytesIntoTheChartRange() {
        // A corrupt/out-of-range byte displays at the slider's own end value.
        XCTAssertEqual(Readout.signed(-64, range: -50...50), "-50")
        XCTAssertEqual(Readout.signed(99, range: -3...3), "+3")
    }

    func testPanpotMatchesTheChartTable() {
        // TABLE 2 +26: 0~64~127 = L64~CNT~R63.
        XCTAssertEqual(Readout.panpot(0), "L64")
        XCTAssertEqual(Readout.panpot(63), "L1")
        XCTAssertEqual(Readout.panpot(64), "CNT")
        XCTAssertEqual(Readout.panpot(65), "R1")
        XCTAssertEqual(Readout.panpot(127), "R63")
    }

    func testUnsignedAppendsUnits() {
        XCTAssertEqual(Readout.unsigned(87), "87")
        XCTAssertEqual(Readout.unsigned(64, unit: "%"), "64 %")
    }
}
