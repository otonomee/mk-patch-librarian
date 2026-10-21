import XCTest
@testable import Models
import PBAPI

/// Regression tests for the TABLE 3 (Vocoder) byte-offset map.
///
/// Expected values are transcribed from the microKORG's own factory bank
/// (`microkorg-voice-bank.syx`), which contains 16 vocoder factory programs —
/// indices 56...63 and 120...127. Program 56 ("Patch 57") is the reference
/// program below; its TABLE 3 bytes were measured directly. Tests skip unless
/// `MKSE_REFERENCE_DUMPS_DIR` is set.
final class VocoderProgramTests: XCTestCase {

    /// Set `MKSE_REFERENCE_DUMPS_DIR` to a local directory of Korg factory
    /// `.syx` dumps to run these; otherwise they skip so the suite still
    /// passes on a clean checkout.
    private func loadFactoryBank() throws -> [UInt8] {
        guard let dir = ProcessInfo.processInfo.environment["MKSE_REFERENCE_DUMPS_DIR"] else {
            throw XCTSkip("MKSE_REFERENCE_DUMPS_DIR not set; skipping factory-bank test")
        }
        let path = "\(dir)/microkorg-voice-bank.syx"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("microkorg-voice-bank.syx not found under MKSE_REFERENCE_DUMPS_DIR; skipping")
        }
        let parsed = try KorgSysEx.parse([UInt8](try Data(contentsOf: URL(fileURLWithPath: path))))
        return parsed.data
    }

    /// Program 56 = "Patch 57", the first vocoder factory program.
    private func loadPatch57() throws -> MicroKORGProgram {
        let bank = try loadFactoryBank()
        let program = try KorgSysEx.program(56, inBank: bank)
        guard let p = MicroKORGProgram(data: program) else {
            XCTFail("254-byte program must decode")
            throw XCTSkip("unreachable")
        }
        return p
    }

    // MARK: Inventory

    func testFactoryBankHas16VocoderPrograms() throws {
        let bank = try loadFactoryBank()
        var vocoderIndices: [Int] = []
        for index in 0..<KorgSysEx.programsPerBank {
            let program = try KorgSysEx.program(index, inBank: bank)
            if let p = MicroKORGProgram(data: program), p.voiceMode == .vocoder {
                vocoderIndices.append(index)
            }
        }
        XCTAssertEqual(vocoderIndices, [56, 57, 58, 59, 60, 61, 62, 63,
                                        120, 121, 122, 123, 124, 125, 126, 127],
                       "the 16 vocoder factory programs are bank D's slots")
    }

    // MARK: Reference values from "Patch 57" (index 56)

    func testPatch57HeaderAndPitch() throws {
        let p = try loadPatch57()
        XCTAssertEqual(p.voiceMode, .vocoder)
        XCTAssertEqual(p.name, "Patch 57")
        // TABLE 3 header: +0..+6
        XCTAssertEqual(p.vocoderMidiChannel(), 255)     // -1 = follow global
        XCTAssertEqual(p.vocoderAssignMode(), 1)        // Poly
        XCTAssertEqual(p.vocoderUnisonDetune(), 0)
        XCTAssertEqual(p.vocoderTune(), 0)              // 0x40 -> 0
        XCTAssertEqual(p.vocoderBendRange(), 12)        // 0x4C -> +12
        XCTAssertEqual(p.vocoderTranspose(), 0)
        XCTAssertEqual(p.vocoderVibratoIntensity(), 5)  // 0x45 -> +5
    }

    func testPatch57OscillatorAndMixer() throws {
        let p = try loadPatch57()
        // +7..+10 oscillator
        XCTAssertEqual(p.vocoderOscWave(), .pulse)
        XCTAssertEqual(p.vocoderOscControl1(), 88)
        XCTAssertEqual(p.vocoderOscControl2(), 12)
        XCTAssertEqual(p.vocoderDwgsWave(), 25)
        // +12, +18..+20 audio-in / envelope follower
        XCTAssertEqual(p.vocoderHpfGate(), true)
        XCTAssertEqual(p.vocoderHpfLevel(), 50)
        XCTAssertEqual(p.vocoderGateSense(), 110)
        XCTAssertEqual(p.vocoderThreshold(), 0)
        // +14..+17 pitch(2) + mixer
        XCTAssertEqual(p.vocoderPortamento(), 2)
        XCTAssertEqual(p.vocoderOscLevel(), 127)
        XCTAssertEqual(p.vocoderExtLevel(), 0)
        XCTAssertEqual(p.vocoderNoiseLevel(), 20)
    }

    func testPatch57FilterAndAmp() throws {
        let p = try loadPatch57()
        // +21..+26 filter
        XCTAssertEqual(p.vocoderFilterShift(), .zero)
        XCTAssertEqual(p.vocoderFilterCutoff(), 11)     // 0x4B -> +11
        XCTAssertEqual(p.vocoderFilterResonance(), 39)
        XCTAssertEqual(p.vocoderFilterModSource(), .aeg)
        XCTAssertEqual(p.vocoderFilterIntensity(), -17) // 0x2F -> -17
        XCTAssertEqual(p.vocoderEfSense(), 127)         // Hold
        XCTAssertTrue(p.vocoderEfSenseIsHold())
        // +27..+31 amp
        XCTAssertEqual(p.vocoderAmpLevel(), 127)
        XCTAssertEqual(p.vocoderDirectLevel(), 10)
        XCTAssertEqual(p.vocoderDistortion(), false)
        XCTAssertEqual(p.vocoderVelSense(), 0)          // 0x40 -> 0
        XCTAssertEqual(p.vocoderKeyTrack(), 0)
    }

    func testPatch57EnvelopesAndLfos() throws {
        let p = try loadPatch57()
        // +32..+35 EG1: the chart fixes these at 0/0/127/0 — factory confirms.
        XCTAssertEqual(p.vocoderEg1Attack(), 0)
        XCTAssertEqual(p.vocoderEg1Decay(), 0)
        XCTAssertEqual(p.vocoderEg1Sustain(), 127)
        XCTAssertEqual(p.vocoderEg1Release(), 0)
        // +36..+39 EG2 (amp)
        XCTAssertEqual(p.vocoderEg2Attack(), 12)
        XCTAssertEqual(p.vocoderEg2Decay(), 33)
        XCTAssertEqual(p.vocoderEg2Sustain(), 82)
        XCTAssertEqual(p.vocoderEg2Release(), 20)
        // +40..+42 LFO1
        XCTAssertEqual(p.vocoderLfo1Wave()?.rawValue, 2)
        XCTAssertEqual(p.vocoderLfo1Frequency(), 66)
        XCTAssertEqual(p.vocoderLfo1TempoSync(), false)
        XCTAssertEqual(p.vocoderLfo1SyncNote(), 11)
        // +43..+45 LFO2
        XCTAssertEqual(p.vocoderLfo2Wave()?.rawValue, 2)
        XCTAssertEqual(p.vocoderLfo2Frequency(), 68)
        XCTAssertEqual(p.vocoderLfo2TempoSync(), false)
        XCTAssertEqual(p.vocoderLfo2SyncNote(), 2)
    }

    func testPatch57BandLevelsPansAndEfHold() throws {
        let p = try loadPatch57()
        // +46..+61 band levels: factory sets all 16 slots (8 pairs) to 127.
        for band in 0..<MicroKORGProgram.vocoderBandCount {
            XCTAssertEqual(p.vocoderBandLevel(band), 127, "band \(band)")
            XCTAssertEqual(p.vocoderBandPan(band), 64, "pan \(band) is center")
        }
        XCTAssertNil(p.vocoderBandLevel(8), "only 8 bands")
        XCTAssertNil(p.vocoderBandPan(-1))
        // +78..+141 E.F. hold, abs 116..179 — measured big-endian values.
        XCTAssertEqual(p.vocoderEfHoldLevel(0), 0x1BA811)
        XCTAssertEqual(p.vocoderEfHoldLevel(1), 0x055D38)
        XCTAssertEqual(p.vocoderEfHoldLevel(15), 0x0013D8)
        XCTAssertNil(p.vocoderEfHoldLevel(16), "only 16 channels")
    }

    // MARK: Region boundaries (chart's "38~141" row is a typo — see model header)

    func testVocoderRegionConstants() {
        XCTAssertEqual(MicroKORGProgram.vocoderBase, 38)
        XCTAssertEqual(MicroKORGProgram.vocoderLast, 179)
        XCTAssertEqual(MicroKORGProgram.vocoderDummyStart, 180)
    }

    func testFactoryPatch57HasZeroDummyRegionAndEfLowBytes() throws {
        let p = try loadPatch57()
        let data = p.data
        XCTAssertTrue(data[MicroKORGProgram.vocoderDummyStart...253].allSatisfy { $0 == 0 },
                      "dummy bytes 180..253 are zero in the factory bank")
        for channel in 0..<MicroKORGProgram.vocoderChannelCount {
            let o = MicroKORGProgram.vocoderBase + 78 + channel * 4
            XCTAssertEqual(data[o + 3], 0, "E.F. hold LOW byte of channel \(channel) is 00h")
        }
    }

    // MODE SEPARATION

    func testVocoderAccessorsAreNilOnSingleModeProgram() throws {
        // "Mkinit" reference voice dump is Single mode.
        guard let dir = ProcessInfo.processInfo.environment["MKSE_REFERENCE_DUMPS_DIR"] else {
            throw XCTSkip("MKSE_REFERENCE_DUMPS_DIR not set; skipping")
        }
        let path = "\(dir)/microkorg-voice.syx"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("microkorg-voice.syx not found under MKSE_REFERENCE_DUMPS_DIR; skipping")
        }
        let p = try MicroKORGProgram.fromSysEx([UInt8](try Data(contentsOf: URL(fileURLWithPath: path))))
        XCTAssertEqual(p.voiceMode, .single)
        XCTAssertNil(p.vocoderMidiChannel())
        XCTAssertNil(p.vocoderTune())
        XCTAssertNil(p.vocoderOscWave())
        XCTAssertNil(p.vocoderBandLevel(0))
        XCTAssertNil(p.vocoderEfHoldLevel(0))
    }

    func testTimbreAccessorsAreNilInVocoderMode() throws {
        let p = try loadPatch57()
        let t = MicroKORGProgram.Timbre.one
        XCTAssertNil(p.midiChannel(t))
        XCTAssertNil(p.osc1Wave(t))
        XCTAssertNil(p.filterCutoff(t))
        XCTAssertNil(p.eg2Attack(t))
        XCTAssertNil(p.lfo1Frequency(t))
    }

    // MARK: Setters

    func testVocoderSettersRoundTrip() throws {
        var p = try loadPatch57()

        p.setVocoderMidiChannel(7);            XCTAssertEqual(p.vocoderMidiChannel(), 7)
        p.setVocoderAssignMode(2);             XCTAssertEqual(p.vocoderAssignMode(), 2)
        p.setVocoderUnisonDetune(42);          XCTAssertEqual(p.vocoderUnisonDetune(), 42)
        p.setVocoderTune(-50);                 XCTAssertEqual(p.vocoderTune(), -50)
        p.setVocoderBendRange(12);             XCTAssertEqual(p.vocoderBendRange(), 12)
        p.setVocoderTranspose(-24);            XCTAssertEqual(p.vocoderTranspose(), -24)
        p.setVocoderVibratoIntensity(-63);     XCTAssertEqual(p.vocoderVibratoIntensity(), -63)
        p.setVocoderOscWave(.dwgs);            XCTAssertEqual(p.vocoderOscWave(), .dwgs)
        p.setVocoderOscControl1(64);           XCTAssertEqual(p.vocoderOscControl1(), 64)
        p.setVocoderHpfGate(false);            XCTAssertEqual(p.vocoderHpfGate(), false)
        p.setVocoderPortamento(127);           XCTAssertEqual(p.vocoderPortamento(), 127)
        p.setVocoderFilterShift(.up2);         XCTAssertEqual(p.vocoderFilterShift(), .up2)
        p.setVocoderFilterCutoff(-63);         XCTAssertEqual(p.vocoderFilterCutoff(), -63)
        p.setVocoderFilterModSource(.lfo2);    XCTAssertEqual(p.vocoderFilterModSource(), .lfo2)
        p.setVocoderEfSense(50);               XCTAssertEqual(p.vocoderEfSense(), 50)
        XCTAssertFalse(p.vocoderEfSenseIsHold())
        p.setVocoderEfSense(127);              XCTAssertTrue(p.vocoderEfSenseIsHold())
        p.setVocoderDistortion(true);          XCTAssertEqual(p.vocoderDistortion(), true)
        p.setVocoderEg2Sustain(100);           XCTAssertEqual(p.vocoderEg2Sustain(), 100)
        p.setVocoderLfo1TempoSync(true);       XCTAssertEqual(p.vocoderLfo1TempoSync(), true)
        p.setVocoderLfo2SyncNote(14);          XCTAssertEqual(p.vocoderLfo2SyncNote(), 14)
    }

    func testBandSettersFillBothHalfPairs() throws {
        var p = try loadPatch57()
        p.setVocoderBandLevel(55, 2)
        XCTAssertEqual(p.vocoderBandLevel(2), 55)
        XCTAssertEqual(p.data[MicroKORGProgram.vocoderBase + 46 + 4], 55)
        XCTAssertEqual(p.data[MicroKORGProgram.vocoderBase + 46 + 5], 55,
                       "CH LEVEL [n] and [n+1] must match")
        p.setVocoderBandPan(100, 3)
        XCTAssertEqual(p.vocoderBandPan(3), 100)
        XCTAssertEqual(p.data[MicroKORGProgram.vocoderBase + 62 + 6], 100)
        XCTAssertEqual(p.data[MicroKORGProgram.vocoderBase + 62 + 7], 100)
        // Out-of-range band writes must be ignored.
        p.setVocoderBandLevel(1, 8)
        p.setVocoderBandPan(1, -1)
        XCTAssertEqual(p.vocoderBandLevel(7), 127)
    }

    func testEfHoldLevelRoundTripClampAndLowByteZero() throws {
        var p = try loadPatch57()
        p.setVocoderEfHoldLevel(0x123456, 15)
        XCTAssertEqual(p.vocoderEfHoldLevel(15), 0x123456)
        let o = MicroKORGProgram.vocoderBase + 78 + 15 * 4
        XCTAssertEqual(p.data[o], 0x12)
        XCTAssertEqual(p.data[o + 1], 0x34)
        XCTAssertEqual(p.data[o + 2], 0x56)
        XCTAssertEqual(p.data[o + 3], 0, "LOW byte stays 00h")

        p.setVocoderEfHoldLevel(0xFFFFFF, 0)   // above 0x7FFFFF -> clamp
        XCTAssertEqual(p.vocoderEfHoldLevel(0), 0x7FFFFF)
        p.setVocoderEfHoldLevel(-100, 0)       // below 0 -> clamp
        XCTAssertEqual(p.vocoderEfHoldLevel(0), 0)
        p.setVocoderEfHoldLevel(1, 16)         // out of range -> ignored
        XCTAssertEqual(p.vocoderEfHoldLevel(16), nil)
    }

    func testVocoderWritesNeverTouchCommonOrDummyBytes() throws {
        var p = try loadPatch57()
        let before = p.data
        p.setVocoderMidiChannel(1)
        p.setVocoderTune(10)
        p.setVocoderOscWave(.noise)
        p.setVocoderBandLevel(10, 7)
        p.setVocoderBandPan(20, 7)
        p.setVocoderEfHoldLevel(0x7FFFFF, 15)
        p.setVocoderEg2Attack(1)
        // Common region (name, arp, FX, EQ — bytes 0..37) untouched:
        XCTAssertEqual(Array(p.data[0..<MicroKORGProgram.vocoderBase]),
                       Array(before[0..<MicroKORGProgram.vocoderBase]))
        // Dummy region (180..253) untouched:
        XCTAssertEqual(Array(p.data[MicroKORGProgram.vocoderDummyStart...253]),
                       Array(before[MicroKORGProgram.vocoderDummyStart...253]))
    }
}
