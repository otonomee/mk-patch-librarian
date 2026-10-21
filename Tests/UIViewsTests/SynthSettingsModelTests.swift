import XCTest
@testable import UIViews
import Models
import PBAPI

/// Settings window state machine: read-on-open, explicit ack-gated save,
/// read-back verification. Driven by a fake transport — no hardware.
final class SynthSettingsModelTests: XCTestCase {

    private struct Boom: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    /// Synchronous fake synth: holds a GlobalSettings "in memory".
    private final class FakeSynth {
        var stored = GlobalSettings.blank()
        var readError: Error?
        var writeError: Error?
        /// Simulates a synth that normalizes or ignores what it's sent.
        var storeTransform: (GlobalSettings) -> GlobalSettings = { $0 }
        var reads = 0
        var writes: [GlobalSettings] = []
        var progress: [String] = []

        var transport: SynthSettingsModel.Transport {
            SynthSettingsModel.Transport(
                read: { progress, done in
                    self.reads += 1
                    progress("Reading settings…")
                    self.progress.append("Reading settings…")
                    if let error = self.readError { done(.failure(error)) } else { done(.success(self.stored)) }
                },
                write: { settings, progress, done in
                    progress("Saving…")
                    self.writes.append(settings)
                    if let error = self.writeError { done(.failure(error)); return }
                    self.stored = self.storeTransform(settings)
                    done(.success(()))
                }
            )
        }
    }

    func testStartsNeutralNotWithAConfidentDefault() {
        let model = SynthSettingsModel(transport: FakeSynth().transport)
        XCTAssertNil(model.draft, "nothing is shown as a value before the synth answers")
        XCTAssertFalse(model.isLoaded)
        XCTAssertFalse(model.canSave)
    }

    func testLoadAdoptsSynthValues() {
        let synth = FakeSynth()
        synth.stored.setTranspose(-3)
        let model = SynthSettingsModel(transport: synth.transport)
        model.load()
        XCTAssertEqual(model.draft?.transpose, -3)
        XCTAssertTrue(model.isLoaded)
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.statusIsError)
    }

    func testLoadFailureLeavesNoValuesAndExplains() {
        let synth = FakeSynth()
        synth.readError = Boom()
        let model = SynthSettingsModel(transport: synth.transport)
        model.load()
        XCTAssertNil(model.draft)
        XCTAssertTrue(model.statusIsError)
        XCTAssertTrue(model.status?.contains("boom") == true)
    }

    func testTimeoutHintsAtMidiChannel() {
        let synth = FakeSynth()
        synth.readError = MIDIError.timeout
        let model = SynthSettingsModel(transport: synth.transport)
        model.load()
        XCTAssertTrue(model.status?.contains("channel 1") == true, model.status ?? "nil")
    }

    func testEditMakesDirtyAndRevertRestores() {
        let model = SynthSettingsModel(transport: FakeSynth().transport)
        model.load()
        model.edit { $0.setMasterTune(15) }
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(model.canSave)
        model.revert()
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.draft?.masterTune, 0)
    }

    func testEditBeforeLoadIsIgnored() {
        let model = SynthSettingsModel(transport: FakeSynth().transport)
        model.edit { $0.setMasterTune(15) }
        XCTAssertNil(model.draft)
    }

    func testSaveWritesDraftThenVerifiesByReadBack() {
        let synth = FakeSynth()
        let model = SynthSettingsModel(transport: synth.transport)
        model.load()
        model.edit { $0.setTranspose(7) }
        model.save()

        XCTAssertEqual(synth.writes.count, 1)
        XCTAssertEqual(synth.writes.first?.transpose, 7)
        XCTAssertEqual(synth.reads, 2, "save is verified by reading the settings back")
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.statusIsError)
        XCTAssertEqual(model.status, "Saved to microKORG")
    }

    /// Measured live: editing again after a save left "Saved to microKORG"
    /// showing (in green) over unsaved changes.
    func testEditingAfterSaveClearsTheSavedStatus() {
        let model = SynthSettingsModel(transport: FakeSynth().transport)
        model.load()
        model.edit { $0.setMasterTune(1) }
        model.save()
        XCTAssertEqual(model.status, "Saved to microKORG")
        model.edit { $0.setMasterTune(0) }
        XCTAssertNil(model.status)
        XCTAssertTrue(model.isDirty)
    }

    func testSaveDoesNothingWhenClean() {
        let synth = FakeSynth()
        let model = SynthSettingsModel(transport: synth.transport)
        model.load()
        model.save()
        XCTAssertTrue(synth.writes.isEmpty)
    }

    func testSaveFailureKeepsEditsAndReportsError() {
        let synth = FakeSynth()
        synth.writeError = Boom()
        let model = SynthSettingsModel(transport: synth.transport)
        model.load()
        model.edit { $0.setTranspose(7) }
        model.save()
        XCTAssertTrue(model.isDirty, "a failed save must not pretend the edits landed")
        XCTAssertEqual(model.draft?.transpose, 7)
        XCTAssertTrue(model.statusIsError)
        XCTAssertTrue(model.status?.hasPrefix("Save failed") == true)
    }

    func testReadBackMismatchIsReported() {
        let synth = FakeSynth()
        synth.storeTransform = { written in
            var s = written
            s.setTranspose(0)
            return s
        }
        let model = SynthSettingsModel(transport: synth.transport)
        model.load()
        model.edit { $0.setTranspose(7) }
        model.save()
        XCTAssertTrue(model.statusIsError)
        XCTAssertEqual(model.draft?.transpose, 0, "show what the synth actually holds")
    }

    /// The app only speaks on channel 1, so after moving the synth off it a
    /// read-back can't succeed — don't attempt one and don't call it a failure.
    func testSavingAChannelChangeSkipsReadBackAndWarns() {
        let synth = FakeSynth()
        let model = SynthSettingsModel(transport: synth.transport)
        model.load()
        model.edit { $0.setMidiChannel(7) }
        model.save()
        XCTAssertEqual(synth.reads, 1)
        XCTAssertFalse(model.isDirty)
        XCTAssertTrue(model.status?.contains("channel 8") == true, model.status ?? "nil")
    }
}
