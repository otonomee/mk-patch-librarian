import XCTest
import Models
@testable import UIViews

/// Undo/redo + New Program (handoff v8, next-step 2).
///
/// `EditorState` snapshots the 254-byte program inside `mutate`, so every
/// editor control is covered by construction. These tests drive real TABLE 1/2
/// setters and assert byte-exact restores. Coalescing is deterministic in
/// tests because `undoCoalesceWindow` is set explicitly: 0 records every
/// change, a large value merges a scripted burst into one undo step.
final class EditorStateUndoTests: XCTestCase {

    private func makeState(coalesce: TimeInterval) -> EditorState {
        let state = EditorState(rawData: MicroKORGProgram.blank().data)
        state.undoCoalesceWindow = coalesce
        return state
    }

    // MARK: Basic round trip

    func testEditThenUndoRestoresBytesAndSwapsFlags() {
        let state = makeState(coalesce: 0)
        let original = state.program.data
        XCTAssertEqual(state.filterCutoff, 127, "blank() opens the cutoff")

        state.filterCutoff = 99

        XCTAssertTrue(state.canUndo)
        XCTAssertFalse(state.canRedo)

        state.undo()

        XCTAssertEqual(state.program.data, original, "undo must restore bytes exactly")
        XCTAssertFalse(state.canUndo)
        XCTAssertTrue(state.canRedo)
    }

    func testRedoReappliesUndoneEdit() {
        let state = makeState(coalesce: 0)
        state.filterCutoff = 99
        state.undo()

        state.redo()

        XCTAssertEqual(state.filterCutoff, 99)
        XCTAssertTrue(state.canUndo)
        XCTAssertFalse(state.canRedo)
    }

    func testUndoRedoIsIdempotentAtStackEdges() {
        let state = makeState(coalesce: 0)
        let original = state.program.data

        state.undo() // nothing recorded yet
        state.redo() // nothing undone yet
        XCTAssertTrue(state.undoStack.isEmpty)
        XCTAssertTrue(state.redoStack.isEmpty)
        XCTAssertEqual(state.program.data, original)

        state.filterCutoff = 42
        state.undo()
        state.undo() // stack empty again
        XCTAssertEqual(state.program.data, original)
        XCTAssertEqual(state.redoStack.count, 1)
    }

    func testNameChangeIsUndoable() {
        let state = makeState(coalesce: 0)
        state.patchName = "Sweep Pad"

        state.undo()

        XCTAssertEqual(state.patchName, "Init")
    }

    func testNewEditClearsRedoStack() {
        let state = makeState(coalesce: 0)
        state.filterCutoff = 42
        state.undo()
        XCTAssertTrue(state.canRedo)

        state.filterCutoff = 77

        XCTAssertFalse(state.canRedo, "a fresh edit invalidates the redo branch")
    }

    // MARK: No-op edits and non-program published changes

    func testNoOpEditAndStatusChangesRecordNothing() {
        let state = makeState(coalesce: 0)
        state.filterCutoff = state.filterCutoff // same byte in, same byte out
        state.status = "some status"
        state.isBusy = true

        XCTAssertTrue(state.undoStack.isEmpty)
        XCTAssertFalse(state.canUndo)
    }

    // MARK: Coalescing (slider drags)

    func testBurstWithinWindowCollapsesToOneUndoStep() {
        let state = makeState(coalesce: 60)
        let original = state.program.data

        // Two changes inside the window = one gesture.
        state.filterCutoff = 99
        state.filterResonance = 50

        XCTAssertEqual(state.undoStack.count, 1)

        state.undo()

        XCTAssertEqual(state.program.data, original,
                       "one undo reverses the whole burst")
        XCTAssertFalse(state.canUndo)
    }

    func testZeroWindowRecordsEveryChange() {
        let state = makeState(coalesce: 0)
        let original = state.program.data
        state.filterCutoff = 99
        state.filterResonance = 50
        XCTAssertEqual(state.undoStack.count, 2)

        state.undo()
        // LIFO: the first undo reverts the LAST edit (resonance), while the
        // earlier cutoff edit is still applied.
        XCTAssertEqual(state.filterCutoff, 99)
        XCTAssertEqual(state.filterResonance, 20, "resonance back to blank's value")

        state.undo()
        XCTAssertEqual(state.program.data, original)
    }

    func testUndoResetsCoalescingSoNextEditRecords() {
        // A bug here would silently swallow the first edit after an undo
        // (it would fall inside the previous burst's window).
        let state = makeState(coalesce: 60)
        state.filterCutoff = 99
        state.undo()

        state.filterCutoff = 55

        XCTAssertEqual(state.undoStack.count, 1, "post-undo edit must record")
        XCTAssertTrue(state.canRedo == false, "redo branch cleared by new edit")
    }

    // MARK: Stack cap

    func testUndoStackDepthIsCapped() {
        let state = makeState(coalesce: 0)
        for value in 1...105 { // distinct consecutive values -> 105 records
            state.filterCutoff = UInt8(value)
        }
        XCTAssertEqual(state.undoStack.count, 100)
    }

    // MARK: Document switches

    func testLoadOfDifferentContentClearsHistory() {
        let state = makeState(coalesce: 0)
        state.filterCutoff = 42
        XCTAssertFalse(state.undoStack.isEmpty)

        var other = MicroKORGProgram.blank()
        other.setName("Loaded")
        state.load(rawData: other.data)

        XCTAssertEqual(state.patchName, "Loaded")
        XCTAssertTrue(state.undoStack.isEmpty)
        XCTAssertTrue(state.redoStack.isEmpty)
    }

    func testLoadOfInvalidBytesKeepsBufferAndHistory() {
        let state = makeState(coalesce: 0)
        state.filterCutoff = 42
        let afterEdit = state.program.data

        state.load(rawData: [0x01, 0x02, 0x03]) // wrong size: ignored

        XCTAssertEqual(state.program.data, afterEdit, "invalid load keeps buffer")
        XCTAssertFalse(state.undoStack.isEmpty, "nothing changed -> history stays")
    }

    // MARK: New Program dialog

    func testStartNewProgramReplacesBufferClearsHistoryAndReports() {
        let state = makeState(coalesce: 0)
        state.filterCutoff = 42 // history exists
        state.patchName = "Old"

        state.startNewProgram(name: "  My Pad  ")

        var expected = MicroKORGProgram.blank()
        expected.setName("My Pad")
        XCTAssertEqual(state.program.data, expected.data, "blank init + trimmed name")
        XCTAssertEqual(state.patchName, "My Pad")
        XCTAssertEqual(state.voiceMode, .single, "vocoder mode must reset too")
        XCTAssertFalse(state.canUndo)
        XCTAssertFalse(state.canRedo)
        XCTAssertEqual(state.status,
                       "New program \"My Pad\" — not sent to the synth yet")
    }

    func testStartNewProgramWithBlankNameFallsBackToInit() {
        let state = makeState(coalesce: 0)

        state.startNewProgram(name: "   ")

        XCTAssertEqual(state.patchName, "Init")
    }

    func testNewProgramIsUndoableNothingMore() {
        // New Program clears history — a subsequent edit starts a fresh stack.
        let state = makeState(coalesce: 0)
        state.filterCutoff = 42
        state.startNewProgram(name: "Fresh")

        state.filterCutoff = 7

        XCTAssertEqual(state.undoStack.count, 1)
        state.undo()
        XCTAssertEqual(state.patchName, "Fresh", "undo reverts to the new blank")
        XCTAssertEqual(state.filterCutoff, 127)
    }

    // MARK: v13 §4.1 — voice mode is writable, editedTimbre is not history

    func testVoiceModeChangeIsUndoableByteChange() {
        let state = makeState(coalesce: 0)
        let original = state.program.data

        state.voiceMode = .layer

        XCTAssertEqual(state.voiceMode, .layer)
        XCTAssertEqual((state.program.data[16] >> 4) & 3, VoiceMode.layer.rawValue)
        XCTAssertEqual(state.undoStack.count, 1, "byte 16 changed — one undo step")

        state.undo()
        XCTAssertEqual(state.program.data, original, "undo restores byte 16")
        XCTAssertEqual(state.voiceMode, .single)
    }

    func testEditedTimbreIsNeverInUndoHistory() {
        let state = makeState(coalesce: 0)
        let original = state.program.data
        state.voiceMode = .layer // one real (undoable) edit
        let beforeSwitch = state.program.data

        state.editedTimbre = .two

        XCTAssertEqual(state.editedTimbre, .two)
        XCTAssertEqual(state.program.data, beforeSwitch, "switching touches no bytes")
        XCTAssertEqual(state.undoStack.count, 1, "switching timbre records nothing")
        state.undo()
        XCTAssertEqual(state.program.data, original, "undo skips UI-only state")
        XCTAssertEqual(state.editedTimbre, .two, "picker position survives undo")
    }

    func testLeavingLayerResetsTimbreToFirst() {
        let state = makeState(coalesce: 0)
        state.voiceMode = .layer
        state.editedTimbre = .two

        state.voiceMode = .single

        XCTAssertEqual(state.editedTimbre, .one,
                       "Single mode must not leave the controls editing T2 bytes")

        state.voiceMode = .layer
        state.editedTimbre = .two
        state.voiceMode = .vocoder
        XCTAssertEqual(state.editedTimbre, .one)
    }

    func testTimbreSwitchChangesWhichBytesAreEdited() {
        let state = makeState(coalesce: 0)
        state.voiceMode = .layer

        state.filterCutoff = 42 // edits the shown timbre (T1)

        XCTAssertEqual(state.program.data[38 + 20], 42)
        XCTAssertEqual(state.program.data[146 + 20], 127, "blank opens T2 cutoff too")

        state.editedTimbre = .two
        XCTAssertEqual(state.filterCutoff, 127, "controls now show Timbre 2")

        state.filterCutoff = 77

        XCTAssertEqual(state.program.data[146 + 20], 77, "writes land in T2")
        XCTAssertEqual(state.program.data[38 + 20], 42, "T1 untouched")
        XCTAssertEqual(state.undoStack.count, 3, "voice mode + two cutoff edits")
    }
}
