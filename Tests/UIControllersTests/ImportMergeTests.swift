import XCTest
import PBAPI
import Models
@testable import UIControllers

/// Regression coverage for a real bug: importing a sparse "taster pack" (a
/// handful of real patches shipped inside a full 128-slot container, the
/// rest left blank) must never blank out program names the browser already
/// had loaded from somewhere else (the synth, a pinned capture, an earlier
/// import). Only slots the import actually names may change.
final class ImportMergeTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        // Redirect session-state persistence to a scratch directory so these
        // tests never read or overwrite the real saved bank in
        // ~/Library/Application Support/MKPatchLibrarian.
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportMergeTests-\(UUID().uuidString)", isDirectory: true)
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

    private func blankProgram() -> [UInt8] {
        [UInt8](repeating: 0, count: KorgSysEx.programDataSize)
    }

    func testSparseImportMergesInsteadOfBlankingExistingNames() {
        let controller = MainWindowController()

        // A real, fully-named bank already loaded (e.g. pulled from the synth).
        var fullBank: [UInt8] = []
        for i in 0..<KorgSysEx.programsPerBank {
            fullBank += namedProgram("Real\(i)")
        }
        controller.applyImportedBank(fullBank)
        XCTAssertEqual(controller.bankNames[0], "Real0")
        XCTAssertEqual(controller.bankNames[50], "Real50")
        XCTAssertEqual(controller.bankNames[127], "Real127")

        // A sparse import: only slots 0 and 1 are named, the other 126 are
        // blank — exactly a 10-patch taster pack shipped as a 128-slot .set.
        var sparseBank: [UInt8] = []
        sparseBank += namedProgram("NEWPATCH")
        sparseBank += namedProgram("SECONDNEW")
        for _ in 2..<KorgSysEx.programsPerBank {
            sparseBank += blankProgram()
        }
        controller.applyImportedBank(sparseBank)

        // The two named slots were updated...
        XCTAssertEqual(controller.bankNames[0], "NEWPATCH")
        XCTAssertEqual(controller.bankNames[1], "SECONDNEW")
        // ...but every other slot kept its prior name. Nothing got blanked.
        XCTAssertEqual(controller.bankNames[2], "Real2")
        XCTAssertEqual(controller.bankNames[50], "Real50")
        XCTAssertEqual(controller.bankNames[127], "Real127")
    }

    func testWrongSizedBankIsIgnoredRatherThanCrashing() {
        let controller = MainWindowController()
        let before = controller.bankNames
        controller.applyImportedBank([0x01, 0x02, 0x03])
        XCTAssertEqual(controller.bankNames, before)
    }

    /// Regression coverage for a real bug: an imported bank only ever lived
    /// in the controller's in-memory @Published state, with no write to
    /// disk — so quitting and relaunching the app (a fresh
    /// `MainWindowController`) silently lost it and fell back to whatever
    /// pinned factory capture happened to be on disk, with no indication
    /// anything had been lost.
    func testImportedBankSurvivesAFreshControllerInstance() {
        let first = MainWindowController()
        // Fully named, not sparse: a sparse bank would merge against
        // whatever `first`'s constructor already pinned in from the real
        // factory capture, making the exact restored names depend on that
        // file's contents. Naming every slot keeps this test deterministic
        // regardless of what's on disk outside the temp session directory.
        var bank: [UInt8] = []
        for i in 0..<KorgSysEx.programsPerBank {
            bank += namedProgram("Survivor\(i)")
        }
        first.applyImportedBank(bank)
        XCTAssertEqual(first.bankNames[0], "Survivor0")
        XCTAssertEqual(first.bankNames[127], "Survivor127")

        // A new instance simulates relaunching the app after quitting.
        let second = MainWindowController()
        XCTAssertEqual(second.bankNames[0], "Survivor0")
        XCTAssertEqual(second.bankNames[127], "Survivor127")
        XCTAssertEqual(second.bankStatus, "Restored 128 program(s) from last session")
    }

    /// Regression coverage for a real bug: saving a patch in the editor only
    /// wrote to the synth over MIDI — nothing told the controller, so the
    /// bank browser grid kept showing the old name after Back, and no toast
    /// fired because `bankStatus` never changed.
    func testSavingInEditorUpdatesBankGridAndStatus() {
        let controller = MainWindowController()
        var bank: [UInt8] = []
        for i in 0..<KorgSysEx.programsPerBank {
            bank += namedProgram("Old\(i)")
        }
        controller.applyImportedBank(bank)
        XCTAssertEqual(controller.bankNames[5], "Old5")

        let saved = namedProgram("NEWNAME")
        controller.updateSavedProgram(bank: 0, patch: 5, data: saved)

        XCTAssertEqual(controller.bankNames[5], "NEWNAME")
        XCTAssertEqual(controller.bankStatus, "Saved \"NEWNAME\" to A.16")

        // And it persists, same as any other change to the bank.
        let reopened = MainWindowController()
        XCTAssertEqual(reopened.bankNames[5], "NEWNAME")
    }
}
