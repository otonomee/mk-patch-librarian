import XCTest
import SwiftUI
@testable import UIViews

/// v15 §3.1 — `ControlGrid` row chunking (pure layout math, no rendering).
final class ControlGridTests: XCTestCase {

    private func cells(_ count: Int, wide: Set<Int> = []) -> [ControlCell] {
        (0..<count).map { i in
            ControlCell(wide: wide.contains(i), content: AnyView(EmptyView()))
        }
    }

    func testTwoColumnsPairsCellsInOrder() {
        let rows = ControlGrid.rows(cells(5), columns: 2)
        XCTAssertEqual(rows.map(\.count), [2, 2, 1], "odd trailing cell gets a short row")
    }

    func testSingleColumnOneCellPerRow() {
        let rows = ControlGrid.rows(cells(3), columns: 1)
        XCTAssertEqual(rows.map(\.count), [1, 1, 1])
    }

    func testWideCellOwnsItsRowAndFlushesPendingCells() {
        // Wide cell at index 1 flushes the pending first cell into a row of
        // its own, then spans a full row, then the rest pair up.
        let rows = ControlGrid.rows(cells(4, wide: [1]), columns: 2)
        XCTAssertEqual(rows.map(\.count), [1, 1, 2])
    }

    func testTrailingWideCellGetsFinalRow() {
        let rows = ControlGrid.rows(cells(3, wide: [2]), columns: 2)
        XCTAssertEqual(rows.map(\.count), [2, 1])
    }

    func testEmptyInputYieldsNoRows() {
        XCTAssertTrue(ControlGrid.rows([], columns: 2).isEmpty)
    }
}
