import XCTest
@testable import Models
import PBAPI

/// Regression tests for the TABLE 6 global-settings map.
///
/// Expected values are cross-checked against the reference
/// `microkorg-global.syx` (skipped unless `MKSE_REFERENCE_DUMPS_DIR` is set).
final class GlobalSettingsTests: XCTestCase {

    /// Set `MKSE_REFERENCE_DUMPS_DIR` to a local directory of Korg factory
    /// `.syx` dumps to run these; otherwise they skip so the suite still
    /// passes on a clean checkout.
    private func loadDump(_ name: String) throws -> [UInt8] {
        guard let dir = ProcessInfo.processInfo.environment["MKSE_REFERENCE_DUMPS_DIR"] else {
            throw XCTSkip("MKSE_REFERENCE_DUMPS_DIR not set; skipping reference-dump test")
        }
        let path = "\(dir)/\(name)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("\(name) not found under MKSE_REFERENCE_DUMPS_DIR; skipping")
        }
        return [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    func testReferenceGlobalDump() throws {
        let settings = try GlobalSettings.fromSysEx(loadDump("microkorg-global.syx"))
        // Values verified by independent Python decode of the same file.
        XCTAssertEqual(settings.masterTune, 0)       // A440
        XCTAssertEqual(settings.transpose, 0)
        XCTAssertEqual(settings.velocityValue, 64)
        XCTAssertEqual(settings.velocityCurve, 2)
        XCTAssertTrue(settings.localControl)
        XCTAssertFalse(settings.memoryProtect)
        XCTAssertEqual(settings.clock, 0)            // Internal
        XCTAssertEqual(settings.midiChannel, 0)      // channel 1
        XCTAssertEqual(settings.syncCtrlCC, 90)
        XCTAssertEqual(settings.timbreSelectCtrlCC, 95)
        XCTAssertEqual(settings.midi1Ctrl, 0)        // P.Bend
        XCTAssertEqual(settings.midi2Ctrl, 3)        // CC#01
        XCTAssertTrue(settings.sysExFilterEnabled)
        XCTAssertTrue(settings.pitchBendFilterEnabled)
        XCTAssertTrue(settings.controlChangeFilterEnabled)
        XCTAssertTrue(settings.programChangeFilterEnabled)

        let knobMap = settings.knobCCMap
        XCTAssertEqual(knobMap.count, 42)
        XCTAssertEqual(knobMap[0], 5)
        XCTAssertEqual(knobMap[18], -1)   // 0xFF = OFF
        XCTAssertEqual(knobMap[41], 0)

        XCTAssertEqual(Array(settings.userScale), [Int](repeating: 0, count: 12))
        XCTAssertEqual(settings.programChangeMap, (0..<128).map { UInt8($0) })
    }

    func testRoundTripThroughSysEx() throws {
        var settings = try GlobalSettings.fromSysEx(loadDump("microkorg-global.syx"))
        let original = KorgSysEx.message(.globalDump, data: settings.data)

        settings.setMasterTune(-25)
        settings.setTranspose(12)
        settings.setKnobCC(42, at: 0)
        settings.setMemoryProtect(true)

        let message = try KorgSysEx.sendGlobal(settings.data)
        let reparsed = try GlobalSettings.fromSysEx(message)
        XCTAssertEqual(reparsed.masterTune, -25)
        XCTAssertEqual(reparsed.transpose, 12)
        XCTAssertEqual(reparsed.knobCCMap[0], 42)
        XCTAssertTrue(reparsed.memoryProtect)
        // Unrelated bytes untouched: only the four setters' targets changed.
        XCTAssertEqual(original.count, message.count)
    }

    func testFromSysExRejectsWrongCommand() throws {
        let voice = try loadDump("microkorg-voice.syx")
        XCTAssertThrowsError(try GlobalSettings.fromSysEx(voice))
    }

    func testBlankHasIdentityProgramMapAndKnobMapOff() {
        let settings = GlobalSettings.blank()
        XCTAssertEqual(settings.data.count, KorgSysEx.globalDataSize)
        XCTAssertEqual(settings.programChangeMap, (0..<128).map { UInt8($0) })
        XCTAssertEqual(settings.knobCCMap, [Int](repeating: -1, count: 42))
        XCTAssertTrue(settings.sysExFilterEnabled)
    }

    func testBitfieldsDoNotClobberNeighbors() {
        var settings = GlobalSettings.blank()
        settings.setLocalControl(false)
        XCTAssertFalse(settings.localControl)
        settings.setMemoryProtect(true)
        XCTAssertTrue(settings.memoryProtect)
        XCTAssertFalse(settings.localControl) // still off
        settings.setLocalControl(true)
        XCTAssertTrue(settings.memoryProtect) // still on
    }

    func testClamping() {
        var settings = GlobalSettings.blank()
        settings.setMasterTune(999)
        XCTAssertEqual(settings.masterTune, 127)
        settings.setMasterTune(-999)
        XCTAssertEqual(settings.masterTune, -128)
        settings.setMidiChannel(42)
        XCTAssertEqual(settings.midiChannel, 10) // 42 & 0x0F
    }

    func testSendGlobalRejectsWrongSize() {
        XCTAssertThrowsError(try KorgSysEx.sendGlobal([0x00, 0x01]))
    }

    // MARK: Settings window support

    func testToSysExRoundTripsExactly() throws {
        var settings = GlobalSettings.blank()
        settings.setMasterTune(-37)
        settings.setVelocityCurve(8)
        let message = settings.toSysEx()
        XCTAssertEqual(Array(message.prefix(5)), [0xF0, 0x42, 0x30, 0x58, 0x51])
        XCTAssertEqual(message.count, 235, "chart NOTE 3: 200 bytes encode to 229 + 6 framing")
        XCTAssertEqual(try GlobalSettings.fromSysEx(message), settings)
    }

    /// The Settings window only edits a handful of scalars and writes the
    /// whole 200-byte block back. Every byte it does not own — knob CC map,
    /// the S's reserved/Speaker/Favorites region — must survive untouched.
    func testScalarEditsTouchOnlyTheirOwnBytes() {
        var data = [UInt8](repeating: 0, count: KorgSysEx.globalDataSize)
        for i in data.indices { data[i] = UInt8((i * 37 + 11) & 0xFF) }
        let original = GlobalSettings(data: data)!
        var edited = original
        edited.setMidiChannel(3)
        edited.setMasterTune(12)
        edited.setTranspose(-5)
        edited.setVelocityCurve(8)
        edited.setVelocityValue(100)
        edited.setClock(2)
        edited.setLocalControl(!original.localControl)
        edited.setMemoryProtect(!original.memoryProtect)

        let owned: Set<Int> = [0, 1, 3, 4, 5, 8, 9]
        for i in 0..<KorgSysEx.globalDataSize where !owned.contains(i) {
            XCTAssertEqual(edited.data[i], original.data[i], "byte \(i) must be preserved")
        }
        // Within the bitfield bytes, unowned bits are preserved too.
        XCTAssertEqual(edited.data[5] & ~0b0101, original.data[5] & ~0b0101)
    }

    func testMasterTuneHz() {
        XCTAssertEqual(GlobalSettings.masterTuneHz(cents: 0), 440.0, accuracy: 0.0001)
        XCTAssertEqual(GlobalSettings.masterTuneHz(cents: -100), 430.0, accuracy: 0.0001)
        XCTAssertEqual(GlobalSettings.masterTuneHz(cents: 100), 450.0, accuracy: 0.0001)
        XCTAssertEqual(GlobalSettings.masterTuneHz(cents: 25), 442.5, accuracy: 0.0001)
    }

    func testVelocityCurveLabels() {
        XCTAssertEqual(GlobalSettings.velocityCurveLabel(0), "1")
        XCTAssertEqual(GlobalSettings.velocityCurveLabel(7), "8")
        XCTAssertEqual(GlobalSettings.velocityCurveLabel(8), "Const")
        XCTAssertEqual(GlobalSettings.velocityCurveCount, 9)
    }
}
