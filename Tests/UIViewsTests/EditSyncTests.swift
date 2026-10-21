import XCTest
import Models
@testable import UIViews

/// Edit Sync parity (handoff v16, §4 item 1): the T1+T2 picker segment mirrors
/// holding TIMBRE SELECT ≥2 s on the hardware (docs/microkorg-s-panel-facts.md
/// p.14 — both timbres receive edits, the display shows T1's value, and Edit
/// Sync is NOT saved with the program).
///
/// Contract under test:
/// - with `editSync`, a per-timbre setter writes BOTH halves in ONE undo step;
/// - reads keep addressing `editedTimbre` (T1) — the display-shows-T1 rule;
/// - `editedTimbre`/`editSync` are pure UI state: never in undo history,
///   never altered by undo/redo;
/// - leaving Layer mode cancels Edit Sync (panel: one press cancels).
final class EditSyncTests: XCTestCase {

    private func makeState(coalesce: TimeInterval = 0) -> EditorState {
        let state = EditorState(rawData: MicroKORGProgram.blank().data)
        state.undoCoalesceWindow = coalesce
        return state
    }

    // MARK: Dual writes

    func testEditSyncWritesBothTimbresInOneUndoStep() {
        let state = makeState()
        let original = state.program.data
        state.editedTimbre = .one
        state.editSync = true

        state.filterCutoff = 42

        XCTAssertEqual(state.program.filterCutoff(.one), 42, "T1 gets the edit")
        XCTAssertEqual(state.program.filterCutoff(.two), 42, "T2 gets the same edit")
        XCTAssertEqual(state.undoStack.count, 1, "both halves share one undo step")

        state.undo()

        XCTAssertEqual(state.program.data, original, "undo restores both timbres exactly")
    }

    func testEditSyncWriteThroughOtherAccessorsToo() {
        let state = makeState()
        state.editedTimbre = .one
        state.editSync = true

        state.filterResonance = 77
        state.ampLevel = 33

        for timbre: MicroKORGProgram.Timbre in [.one, .two] {
            XCTAssertEqual(state.program.filterResonance(timbre), 77)
            XCTAssertEqual(state.program.ampLevel(timbre), 33)
        }
    }

    func testWithoutEditSyncOnlyEditedTimbreChanges() {
        let state = makeState()
        state.editedTimbre = .two
        state.editSync = false

        state.filterCutoff = 42

        XCTAssertEqual(state.program.filterCutoff(.two), 42)
        XCTAssertEqual(state.program.filterCutoff(.one), 127, "T1 untouched")
    }

    // MARK: Reads show T1

    func testReadsAddressEditedTimbreEvenWhileSyncing() {
        let state = makeState()
        // Make T1 and T2 differ, then sync-edit from T1's perspective.
        state.editedTimbre = .two
        state.filterCutoff = 10 // T2 = 10, T1 = 127
        state.editedTimbre = .one
        state.editSync = true

        XCTAssertEqual(state.filterCutoff, 127, "display reads T1 while syncing")

        state.filterCutoff = 55
        XCTAssertEqual(state.filterCutoff, 55, "reads follow the shared write")
        XCTAssertEqual(state.program.filterCutoff(.two), 55)
    }

    // MARK: UI state never in history

    func testEditSyncStateSurvivesUndoRedoAndIsNotInHistory() {
        let state = makeState()
        state.editedTimbre = .one
        state.editSync = true
        state.filterCutoff = 42

        state.undo()

        XCTAssertTrue(state.editSync, "undo restores bytes, not UI selection")
        XCTAssertEqual(state.editedTimbre, .one)

        state.redo()
        XCTAssertTrue(state.editSync)
        XCTAssertEqual(state.program.filterCutoff(.one), 42, "redo re-applies to both")
        XCTAssertEqual(state.program.filterCutoff(.two), 42)
    }

    func testLeavingLayerModeCancelsEditSync() {
        let state = makeState()
        state.editedTimbre = .two
        state.editSync = true

        state.voiceMode = .single

        XCTAssertEqual(state.editedTimbre, .one, "selection resets to T1")
        XCTAssertFalse(state.editSync, "Edit Sync cancels when leaving Layer")
    }

    func testStayingInLayerKeepsEditSync() {
        let state = makeState()
        state.editSync = true

        state.voiceMode = .layer

        XCTAssertTrue(state.editSync, "re-selecting Layer must not cancel sync")
    }

    // MARK: Redo path

    func testEditSyncRedoReappliesToBothTimbres() {
        let state = makeState()
        state.editSync = true

        state.filterCutoff = 42
        state.undo()
        state.redo()

        XCTAssertEqual(state.program.filterCutoff(.one), 42)
        XCTAssertEqual(state.program.filterCutoff(.two), 42)
    }
}
