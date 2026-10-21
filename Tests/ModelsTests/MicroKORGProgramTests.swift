import XCTest
@testable import Models
import PBAPI

/// Regression tests for the TABLE 1/2 byte-offset map.
///
/// Expected values are transcribed from the public micro KORG MIDI
/// Implementation Rev 1.4 and cross-checked against reference `.syx`
/// dumps (skipped unless `MKSE_REFERENCE_DUMPS_DIR` is set).
final class MicroKORGProgramTests: XCTestCase {

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

    private func loadVoiceProgram() throws -> MicroKORGProgram {
        try MicroKORGProgram.fromSysEx(loadDump("microkorg-voice.syx"))
    }

    // MARK: Reference voice dump ("Mkinit")

    func testVoiceDumpDecodesWithCorrectNameAndMode() throws {
        let program = try loadVoiceProgram()
        XCTAssertEqual(program.name, "Mkinit")
        XCTAssertEqual(program.voiceMode, .single)
    }

    func testVoiceDumpProgramLevelBytes() throws {
        let p = try loadVoiceProgram()
        // TABLE 1
        XCTAssertFalse(p.delaySync)
        XCTAssertEqual(p.delayTimeBase, 5)
        XCTAssertEqual(p.delayTime, 40)
        XCTAssertEqual(p.delayDepth, 0)
        XCTAssertEqual(p.delayType, .stereo)
        XCTAssertEqual(p.modFxSpeed, 20)
        XCTAssertEqual(p.modFxDepth, 0)
        XCTAssertEqual(p.modFxType, .chorusFlange)
        XCTAssertEqual(p.eqHiFreq, 20)
        XCTAssertEqual(p.eqHiGain, 0)     // 64 raw -> 0
        XCTAssertEqual(p.eqLowFreq, 15)
        XCTAssertEqual(p.eqLowGain, 0)
        XCTAssertEqual(p.arpTempo, 120)
        XCTAssertFalse(p.arpEnabled)
        XCTAssertEqual(p.arpType, .up)
        XCTAssertEqual(p.arpRange, 0)     // 1 octave
        XCTAssertEqual(p.arpGate, 80)
        XCTAssertEqual(p.arpResolution, 1)
        XCTAssertEqual(p.arpSwing, 0)
        XCTAssertEqual(p.kbdOctave, 0)
    }

    func testVoiceDumpTimbre1Bytes() throws {
        let p = try loadVoiceProgram()
        let t = MicroKORGProgram.Timbre.one
        // TABLE 2
        XCTAssertEqual(p.midiChannel(t), 255)   // -1 = GLB
        XCTAssertEqual(p.assignMode(t), 1)      // Poly
        XCTAssertEqual(p.unisonDetune(t), 10)
        XCTAssertEqual(p.tune(t), 0)            // 64 raw -> 0
        XCTAssertEqual(p.bendRange(t), 2)       // 66 raw -> +2
        XCTAssertEqual(p.transpose(t), 0)
        XCTAssertEqual(p.vibratoIntensity(t), 5)
        XCTAssertEqual(p.osc1Wave(t), .saw)
        XCTAssertEqual(p.osc2Wave(t), .saw)
        XCTAssertEqual(p.osc2Mod(t), .off)
        XCTAssertEqual(p.osc2Semitone(t), 0)
        XCTAssertEqual(p.osc1Level(t), 127)
        XCTAssertEqual(p.osc2Level(t), 0)
        XCTAssertEqual(p.noiseLevel(t), 0)
        XCTAssertEqual(p.filterType(t), .lp12)
        XCTAssertEqual(p.filterCutoff(t), 127)
        XCTAssertEqual(p.filterResonance(t), 20)
        XCTAssertEqual(p.filterEG1Intensity(t), 0)
        XCTAssertEqual(p.ampLevel(t), 127)
        XCTAssertEqual(p.panpot(t), 64)         // center
        XCTAssertFalse(p.distortion(t) ?? true)
        XCTAssertEqual(p.eg1Attack(t), 0)
        XCTAssertEqual(p.eg1Decay(t), 64)
        XCTAssertEqual(p.eg1Sustain(t), 127)
        XCTAssertEqual(p.eg1Release(t), 0)
        XCTAssertEqual(p.eg2Attack(t), 0)
        XCTAssertEqual(p.eg2Decay(t), 64)
        XCTAssertEqual(p.eg2Sustain(t), 127)
        XCTAssertEqual(p.eg2Release(t), 0)
        XCTAssertEqual(p.lfo1Wave(t), .tri)
        XCTAssertEqual(p.lfo1Frequency(t), 10)
        XCTAssertEqual(p.lfo2Wave(t), .sin)
        XCTAssertEqual(p.lfo2Frequency(t), 70)
        XCTAssertEqual(p.patchSource(0, t), .lfo1)
        XCTAssertEqual(p.patchDestination(0, t), .pitch)
        XCTAssertEqual(p.patchIntensity(0, t), 0)
    }

    // MARK: Factory bank structure

    func testFactoryBankVoiceModeDistribution() throws {
        let bank = try KorgSysEx.parse(loadDump("microkorg-voice-bank.syx"))
        XCTAssertEqual(bank.command, .programDump)

        var counts: [VoiceMode: Int] = [:]
        for index in 0..<KorgSysEx.programsPerBank {
            let slice = try KorgSysEx.program(index, inBank: bank.data)
            let program = try XCTUnwrap(MicroKORGProgram(data: slice))
            counts[program.voiceMode, default: 0] += 1
        }
        // Verified against the dumps: 87 Single, 25 Layer, 16 Vocoder.
        XCTAssertEqual(counts[.single], 87)
        XCTAssertEqual(counts[.layer], 25)
        XCTAssertEqual(counts[.vocoder], 16)
    }

    func testFactoryBankNamesAtStride() throws {
        let bank = try KorgSysEx.parse(loadDump("microkorg-voice-bank.syx"))
        let first = try XCTUnwrap(MicroKORGProgram(
            data: try KorgSysEx.program(0, inBank: bank.data)))
        let last = try XCTUnwrap(MicroKORGProgram(
            data: try KorgSysEx.program(127, inBank: bank.data)))
        XCTAssertEqual(first.name, "Patch 1")
        XCTAssertEqual(last.name, "Patch 128")
    }

    /// The 16 vocoder programs are exactly the ones whose byte 57 (timbre1
    /// +19) falls outside 0..3 — in Vocoder mode that region is TABLE 3.
    func testVocoderProgramsUseDifferentLayout() throws {
        let bank = try KorgSysEx.parse(loadDump("microkorg-voice-bank.syx"))
        for index in 0..<KorgSysEx.programsPerBank {
            let program = try XCTUnwrap(MicroKORGProgram(
                data: try KorgSysEx.program(index, inBank: bank.data)))
            if program.voiceMode == .vocoder {
                // Timbre accessors must refuse (TABLE 3, not TABLE 2).
                XCTAssertNil(program.filterCutoff(.one),
                             "vocoder program \(index) must not expose timbre offsets")
            } else {
                XCTAssertNotNil(program.filterCutoff(.one))
            }
        }
    }

    /// Signed params are offset-binary around 64 across the factory bank.
    func testSignedRangesAcrossFactoryBank() throws {
        let bank = try KorgSysEx.parse(loadDump("microkorg-voice-bank.syx"))
        for index in 0..<KorgSysEx.programsPerBank {
            let program = try XCTUnwrap(MicroKORGProgram(
                data: try KorgSysEx.program(index, inBank: bank.data)))
            if program.voiceMode == .vocoder { continue }
            if let bend = program.bendRange(.one) {
                XCTAssertTrue((0...12).contains(bend), "bendRange \(bend) out of range")
            }
            if let transpose = program.transpose(.one) {
                XCTAssertTrue((-24...24).contains(transpose), "transpose \(transpose) out of range")
            }
            if let swing = Optional(program.arpSwing) {
                XCTAssertTrue((-100...100).contains(swing), "swing \(swing) out of range")
            }
            XCTAssertTrue((-3...3).contains(program.kbdOctave),
                          "kbdOctave \(program.kbdOctave) out of range")
        }
    }

    // MARK: blank() is born neutral

    func testBlankIsAudibleAndNeutral() {
        let program = MicroKORGProgram.blank()

        // Every 64-centered (+/-N) byte must sit at its neutral value 64.
        // A zero here means full-negative (e.g. PATCH int 0 = -63 drags pitch
        // out of the audible range — "silent JimBob"), not "off".
        let t = MicroKORGProgram.Timbre.one
        XCTAssertEqual(program.tune(t), 0)
        XCTAssertEqual(program.transpose(t), 0)
        XCTAssertEqual(program.vibratoIntensity(t), 0)
        XCTAssertEqual(program.filterKeyboardTrack(t), 0)
        XCTAssertEqual(program.filterVelocitySense(t), 0)
        XCTAssertEqual(program.filterEG1Intensity(t), 0)
        for index in 0..<4 {
            XCTAssertEqual(program.patchIntensity(index, t), 0, "patch \(index + 1)")
        }
        // And the bytes themselves, not just the accessors.
        XCTAssertEqual(program.data[38 + 3], 64)
        XCTAssertEqual(program.data[38 + 5], 64)
        XCTAssertEqual(program.data[38 + 6], 64)
        XCTAssertEqual(program.data[38 + 22], 64)
        XCTAssertEqual(program.data[38 + 23], 64)
        XCTAssertEqual(program.data[38 + 24], 64)
        XCTAssertEqual(program.data[38 + 28], 64)
        XCTAssertEqual(program.data[38 + 29], 64)
        XCTAssertEqual(program.data[38 + 16], 100) // osc1 level audible
        XCTAssertEqual(program.data[38 + 45], 64)
        XCTAssertEqual(program.data[38 + 47], 64)
        XCTAssertEqual(program.data[38 + 49], 64)
        XCTAssertEqual(program.data[38 + 51], 64)

        // Timbre 2 is filled with the identical neutral-audible block —
        // switching a blank program to Layer must not land on silence.
        let two = MicroKORGProgram.Timbre.two
        XCTAssertEqual(program.tune(two), 0)
        XCTAssertEqual(program.transpose(two), 0)
        XCTAssertEqual(program.vibratoIntensity(two), 0)
        XCTAssertEqual(program.filterKeyboardTrack(two), 0)
        XCTAssertEqual(program.filterVelocitySense(two), 0)
        XCTAssertEqual(program.filterEG1Intensity(two), 0)
        XCTAssertEqual(program.ampVelocitySense(two), 0)
        XCTAssertEqual(program.ampKeyboardTrack(two), 0)
        for index in 0..<4 {
            XCTAssertEqual(program.patchIntensity(index, two), 0, "T2 patch \(index + 1)")
        }
        // Byte-for-byte: the two timbre blocks are identical after blank().
        XCTAssertEqual(
            Array(program.data[38...89]), Array(program.data[146...197]),
            "blank() must fill Timbre 2 like Timbre 1")
        XCTAssertEqual(program.data[146 + 16], 100) // osc1 level audible on T2
    }

    // MARK: Mutations round-trip

    func testMutationsChangeOnlyTargetBytes() {
        var program = MicroKORGProgram.blank()
        let before = program.data

        program.setFilterCutoff(77, .one)
        XCTAssertEqual(program.filterCutoff(.one), 77)
        // Exactly one byte changed.
        let changed = zip(before, program.data).filter { $0 != $1 }.count
        XCTAssertEqual(changed, 1)

        program.setArpEnabled(true)
        XCTAssertTrue(program.arpEnabled)
        program.setArpEnabled(false)
        XCTAssertFalse(program.arpEnabled)

        program.setName("Bass")
        XCTAssertEqual(program.name, "Bass")
        XCTAssertEqual(program.data.count, KorgSysEx.programDataSize)
    }

    func testSettersClampToChartRanges() {
        var program = MicroKORGProgram.blank()
        program.setArpSwing(999)
        XCTAssertEqual(program.arpSwing, 127)
        program.setArpSwing(-999)
        XCTAssertEqual(program.arpSwing, -128)
        program.setKbdOctave(99)
        XCTAssertEqual(program.kbdOctave, 3)
        program.setKbdOctave(-99)
        XCTAssertEqual(program.kbdOctave, -3)
        program.setTune(999, .one)
        XCTAssertEqual(program.tune(.one), 63) // clamped into 0..127 raw
    }

    func testBitfieldsDoNotClobberNeighbors() {
        var program = MicroKORGProgram.blank()
        // Byte 32 packs on/latch/target/keysync; toggling one must keep the rest.
        program.setArpTarget(2)
        program.setArpLatch(true)
        program.setArpEnabled(true)
        XCTAssertTrue(program.arpEnabled)
        XCTAssertTrue(program.arpLatch)
        XCTAssertEqual(program.arpTarget, 2)
        program.setArpEnabled(false)
        XCTAssertTrue(program.arpLatch)
        XCTAssertEqual(program.arpTarget, 2)
    }

    func testVoiceModeByteMatchesChartEncoding() {
        var program = MicroKORGProgram.blank()
        for mode in VoiceMode.allCases {
            program.setVoiceMode(mode)
            XCTAssertEqual(program.voiceMode, mode)
            XCTAssertEqual((program.data[16] >> 4) & 3, mode.rawValue)
        }
    }

    // MARK: v10 §3b — new accessor round-trips

    func testProgramLevelTriggerAndScaleRoundTrip() {
        var program = MicroKORGProgram.blank()
        let before = program.data

        program.setTriggerLength(5)
        XCTAssertEqual(program.triggerLength, 5)
        program.setTriggerPattern(0b1011_0101)
        XCTAssertEqual(program.triggerPattern, 0b1011_0101)
        program.setScaleKey(7)
        XCTAssertEqual(program.scaleKey, 7)
        program.setScaleType(3)
        XCTAssertEqual(program.scaleType, 3)

        // Byte 14 keeps its upper bits; byte 17 halves stay independent.
        XCTAssertEqual(program.data[14] & 0xF8, before[14] & 0xF8)
        XCTAssertEqual(program.data[17] >> 4, 7)
        XCTAssertEqual(program.data[17] & 0x0F, 3)

        // Round-trip back to chart defaults.
        program.setTriggerLength(0)
        program.setTriggerPattern(0)
        program.setScaleKey(0)
        program.setScaleType(0)
        XCTAssertEqual(program.data[17], before[17])
    }

    func testVoiceBitfieldsRoundTripWithoutClobber() {
        var program = MicroKORGProgram.blank()

        program.setAssignMode(2, .one)
        program.setEg2Reset(true, .one)
        program.setEg1Reset(true, .one)
        program.setTriggerMode(true, .one)
        program.setKeyPriority(1, .one)

        XCTAssertEqual(program.assignMode(.one), 2)
        XCTAssertEqual(program.eg2Reset(.one), true)
        XCTAssertEqual(program.eg1Reset(.one), true)
        XCTAssertEqual(program.triggerMode(.one), true)
        XCTAssertEqual(program.keyPriority(.one), 1)

        // Clearing one bit must not disturb its neighbors in byte +1.
        program.setEg1Reset(false, .one)
        XCTAssertEqual(program.assignMode(.one), 2)
        XCTAssertEqual(program.eg2Reset(.one), true)
        XCTAssertEqual(program.triggerMode(.one), true)
        XCTAssertEqual(program.keyPriority(.one), 1)
        XCTAssertEqual(program.eg1Reset(.one), false)

        // Timbre 2 stays untouched by Timbre 1 writes.
        XCTAssertEqual(program.data[146 + 1], MicroKORGProgram.blank().data[146 + 1])
    }

    func testPitchAndOscSettersRoundTrip() {
        var program = MicroKORGProgram.blank()
        let blankByte = { (offset: Int) in MicroKORGProgram.blank().data[38 + offset] }

        program.setBendRange(12, .one)
        XCTAssertEqual(program.bendRange(.one), 12)
        program.setTranspose(-24, .one)
        XCTAssertEqual(program.transpose(.one), -24)
        program.setVibratoIntensity(63, .one)
        XCTAssertEqual(program.vibratoIntensity(.one), 63)
        program.setPortamento(99, .one)
        XCTAssertEqual(program.portamento(.one), 99)
        program.setOsc1Control1(64, .one)
        XCTAssertEqual(program.osc1Control1(.one), 64)
        program.setOsc1Control2(33, .one)
        XCTAssertEqual(program.osc1Control2(.one), 33)
        program.setDwgsWave(63, .one)
        XCTAssertEqual(program.dwgsWave(.one), 63)
        program.setOsc2Tune(-63, .one)
        XCTAssertEqual(program.osc2Tune(.one), -63)

        // Portamento masks bit 7 per chart (+15 B7 "not use").
        program.setPortamento(0xFF, .one)
        XCTAssertEqual(program.data[38 + 15], blankByte(15) & 0x80 | 0x7F)
        XCTAssertEqual(program.portamento(.one), 127)
    }

    func testFilterVelocitySenseAndKbdTrackRoundTrip() {
        var program = MicroKORGProgram.blank()

        program.setFilterVelocitySense(-63, .one)
        XCTAssertEqual(program.filterVelocitySense(.one), -63)
        program.setFilterVelocitySense(63, .one)
        XCTAssertEqual(program.filterVelocitySense(.one), 63)
        program.setFilterKeyboardTrack(12, .one)
        XCTAssertEqual(program.filterKeyboardTrack(.one), 12)
        program.setFilterKeyboardTrack(-63, .one)
        XCTAssertEqual(program.filterKeyboardTrack(.one), -63)

        // +23 and +24 are distinct bytes.
        XCTAssertEqual(program.data[38 + 23], 127)   // 63 + 64 offset-binary
        XCTAssertEqual(program.data[38 + 24], 1)     // -63 + 64
    }

    func testLfoSyncAndKeySyncRoundTrip() {
        var program = MicroKORGProgram.blank()

        program.setLfo1SyncNote(14, .one)
        XCTAssertEqual(program.lfo1SyncNote(.one), 14)
        program.setLfo1KeySync(2, .one)
        XCTAssertEqual(program.lfo1KeySync(.one), 2)
        program.setLfo1TempoSync(true, .one)
        // Tempo-sync bit and sync-note field coexist in byte +40.
        XCTAssertEqual(program.lfo1TempoSync(.one), true)
        XCTAssertEqual(program.lfo1SyncNote(.one), 14)

        program.setLfo2SyncNote(7, .one)
        XCTAssertEqual(program.lfo2SyncNote(.one), 7)
        program.setLfo2KeySync(1, .one)
        XCTAssertEqual(program.lfo2KeySync(.one), 1)
        // Key sync lives in +41 (with the wave) — wave must survive.
        let wave = program.lfo2Wave(.one)
        program.setLfo2KeySync(0, .one)
        XCTAssertEqual(program.lfo2Wave(.one), wave)
        XCTAssertEqual(program.lfo2SyncNote(.one), 7)
    }

    func testPatchSettersRoundTrip() {
        var program = MicroKORGProgram.blank()

        for index in 0..<4 {
            let source = PatchSource.allCases[index]
            let destination = PatchDestination.allCases[index + 1]
            program.setPatchSource(index, source, .one)
            program.setPatchDestination(index, destination, .one)
            program.setPatchIntensity(index, (index - 2) * 20, .one)

            XCTAssertEqual(program.patchSource(index, .one), source)
            XCTAssertEqual(program.patchDestination(index, .one), destination)
            XCTAssertEqual(program.patchIntensity(index, .one), (index - 2) * 20)
        }

        // Out-of-range index writes are no-ops, not crashes.
        program.setPatchSource(-1, .eg1, .one)
        program.setPatchSource(4, .eg1, .one)
        XCTAssertNil(program.patchSource(4, .one))
    }

    // MARK: v13 §3.5 — Timbre 2 (base 146) round-trips

    func testTimbre2AccessorsRoundTrip() {
        var program = MicroKORGProgram.blank()
        let two = MicroKORGProgram.Timbre.two

        // Osc levels (+16, +17), filter (+20, +21), patch 1 (+44, +45).
        program.setOsc1Level(111, two)
        XCTAssertEqual(program.osc1Level(two), 111)
        program.setOsc2Level(55, two)
        XCTAssertEqual(program.osc2Level(two), 55)
        program.setFilterCutoff(77, two)
        XCTAssertEqual(program.filterCutoff(two), 77)
        program.setFilterResonance(42, two)
        XCTAssertEqual(program.filterResonance(two), 42)
        program.setPatchSource(0, .lfo2, two)
        XCTAssertEqual(program.patchSource(0, two), .lfo2)
        program.setPatchDestination(0, .cutoff, two)
        XCTAssertEqual(program.patchDestination(0, two), .cutoff)
        program.setPatchIntensity(0, -30, two)
        XCTAssertEqual(program.patchIntensity(0, two), -30)

        // The writes landed in the Timbre 2 block, not Timbre 1's.
        XCTAssertEqual(program.data[146 + 16], 111)
        XCTAssertEqual(program.data[146 + 20], 77)
        XCTAssertEqual(program.data[146 + 45], 34) // -30 + 64 offset-binary
    }

    func testTimbre2WritesDoNotClobberTimbre1() {
        var program = MicroKORGProgram.blank()
        // Give Timbre 1 distinctive values so a clobber cannot go unnoticed.
        program.setOsc1Level(33, .one)
        program.setFilterCutoff(66, .one)
        program.setPatchIntensity(0, 21, .one)
        let timbre1 = Array(program.data[38...89])

        let two = MicroKORGProgram.Timbre.two
        program.setOsc1Level(111, two)
        program.setOsc2Level(55, two)
        program.setFilterCutoff(77, two)
        program.setFilterResonance(42, two)
        program.setPatchSource(0, .lfo2, two)
        program.setPatchIntensity(0, -30, two)
        program.setAssignMode(2, two)
        program.setKeyPriority(1, two)

        XCTAssertEqual(
            Array(program.data[38...89]), timbre1,
            "Timbre 2 writes must leave Timbre 1 byte-identical")
    }

    /// Program-level bytes a timbre write must never touch.
    func testTimbre2WritesLeaveProgramLevelAlone() {
        var program = MicroKORGProgram.blank()
        program.setName("LevelTest")
        let programLevel = Array(program.data[0...37])

        program.setOsc1Level(111, .two)
        program.setPatchIntensity(3, 60, .two)

        XCTAssertEqual(Array(program.data[0...37]), programLevel)
    }

    // MARK: SysEx entry points

    func testProgramFromBankSysExMatchesSingleSysEx() throws {
        // The first program of the factory bank is "Patch 1"; decode via the
        // full-message path to prove bank extraction shares the map.
        let bankMessage = try loadDump("microkorg-voice-bank.syx")
        let program = try MicroKORGProgram.fromSysEx(bankMessage, bankIndex: 0)
        XCTAssertEqual(program.name, "Patch 1")
        XCTAssertThrowsError(try MicroKORGProgram.fromSysEx(bankMessage, bankIndex: 128))
    }

    func testFromSysExRejectsWrongCommand() throws {
        let global = try loadDump("microkorg-global.syx")
        XCTAssertThrowsError(try MicroKORGProgram.fromSysEx(global))
    }

    func testPatchFromSysEx() throws {
        let patch = try Patch.fromSysEx(bank: 0, patch: 1,
                                        sysExData: loadDump("microkorg-voice.syx"))
        XCTAssertEqual(patch.program.name, "Mkinit")
        XCTAssertEqual(patch.id, "0_1")
    }
}
