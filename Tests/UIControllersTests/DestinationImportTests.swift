import XCTest
import PBAPI
import Models
@testable import UIControllers

/// Coverage for selective import with a destination picker: occupant
/// lookup, conflict detection, and the A/B apply path (pure local state,
/// no MIDI). The C/D write path isn't unit-tested here — same as
/// `loadBankTapped`/`saveToSynth`, it's live-verified against real
/// hardware rather than mocked, since CoreMIDI isn't mockable from this
/// test target.
final class DestinationImportTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DestinationImportTests-\(UUID().uuidString)", isDirectory: true)
        MainWindowController.sessionStateDirectory = tempDir
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func namedProgram(_ name: String) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: KorgSysEx.programDataSize)
        KorgSysEx.setProgramName(name, in: &data)
        return data
    }

    private func importedProgram(name: String, sourceIndex: Int = 0) -> ProgramFileImport.ImportedProgram {
        let program = MicroKORGProgram(data: namedProgram(name))!
        return ProgramFileImport.ImportedProgram(sourceIndex: sourceIndex, hasKnownSourcePosition: true, program: program)
    }

    // MARK: occupantName

    // A/B's constructor can fall back to the real pinned factory capture
    // (a hardcoded path, outside `sessionStateDirectory`), so every A/B slot
    // may already be "occupied" by a real factory name regardless of this
    // test's temp dir — there's no public API to force one back to blank.
    // C/D's `extraBankNames` starts genuinely empty (`[:]`) with no such
    // fallback, so it's the reliable slot for asserting true emptiness.

    func testOccupantNameIsNilForAnEmptyExtraBankSlot() {
        let controller = MainWindowController()
        XCTAssertNil(controller.occupantName(bank: 4, patch: 0))
    }

    func testOccupantNameReturnsTheRealNameForAnOccupiedABSlot() {
        let controller = MainWindowController()
        var bank: [UInt8] = []
        for i in 0..<KorgSysEx.programsPerBank {
            bank += namedProgram(i == 5 ? "Filled" : "Other\(i)")
        }
        controller.applyImportedBank(bank)
        XCTAssertEqual(controller.occupantName(bank: 0, patch: 5), "Filled")
    }

    func testOccupantNameForExtraBankReflectsAPriorSave() {
        let controller = MainWindowController()
        XCTAssertNil(controller.occupantName(bank: 4, patch: 10))
        controller.updateSavedProgram(bank: 4, patch: 10, data: namedProgram("CPatch"))
        XCTAssertEqual(controller.occupantName(bank: 4, patch: 10), "CPatch")
    }

    // MARK: hasConflict

    func testConflictWhenDestinationIsAlreadyOccupied() {
        let controller = MainWindowController()
        var bank: [UInt8] = []
        for i in 0..<KorgSysEx.programsPerBank {
            bank += namedProgram(i == 0 ? "Existing" : "Other\(i)")
        }
        controller.applyImportedBank(bank)
        XCTAssertTrue(controller.hasConflict(bank: 0, patch: 0, among: [(bank: 0, patch: 0)]))
        // An empty C/D slot, targeted once: no occupant, no duplicate.
        XCTAssertFalse(controller.hasConflict(bank: 4, patch: 1, among: [(bank: 4, patch: 1)]))
    }

    func testConflictWhenTwoRowsTargetTheSameDestination() {
        let controller = MainWindowController()
        // C/D slots so occupancy is guaranteed false, isolating the
        // duplicate-within-batch check from the occupied-slot check above.
        let destinations: [(bank: Int, patch: Int)] = [(4, 0), (4, 0), (4, 1)]
        XCTAssertTrue(controller.hasConflict(bank: 4, patch: 0, among: destinations))
        XCTAssertFalse(controller.hasConflict(bank: 4, patch: 1, among: destinations))
    }

    // MARK: applyDestinationAssignments — A/B path (pure local, no MIDI)

    func testApplyingABAssignmentsUpdatesTheGridAndPersists() {
        let controller = MainWindowController()
        let assignments = [
            MainWindowController.ImportDestinationAssignment(
                program: importedProgram(name: "First"), bank: 0, patch: 0
            ),
            MainWindowController.ImportDestinationAssignment(
                program: importedProgram(name: "Second"), bank: 1, patch: 5
            ),
        ]

        let expectation = expectation(description: "completion called")
        controller.applyDestinationAssignments(assignments) { result in
            XCTAssertEqual(result.succeeded, 2)
            XCTAssertTrue(result.failures.isEmpty)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(controller.bankNames[0], "First")
        XCTAssertEqual(controller.bankNames[ProgramSlot.index(bank: 1, patch: 5)], "Second")
        XCTAssertEqual(controller.bankStatus, "Imported 2 program(s)")

        // Persisted, same as any other bank change.
        let reopened = MainWindowController()
        XCTAssertEqual(reopened.bankNames[0], "First")
    }

    func testEmptyAssignmentListCompletesImmediatelyWithNothingDone() {
        let controller = MainWindowController()
        let expectation = expectation(description: "completion called")
        controller.applyDestinationAssignments([]) { result in
            XCTAssertEqual(result.succeeded, 0)
            XCTAssertTrue(result.failures.isEmpty)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }
}
