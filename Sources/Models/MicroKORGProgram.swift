import Foundation
import PBAPI

// MARK: - MicroKORG program model (254-byte decoded dump)
//
// PRIMARY REFERENCE: the *microKORG S MIDI Implementation, Revision 1.01
// (2026.06.22)* at `docs/microkorg-s-midi-implementation-2026.txt` — the
// chart for Austin's instrument. The original *micro KORG MIDI
// Implementation, Revision 1.4 (2002.06.27)* (`docs/
// microkorg-midi-implementation-rev1.4.txt`) is kept for the original
// microKORG and for history. A mechanical table-by-table diff of the two
// lives in `docs/HANDOFF-v12.md` §2.1; the S chart differs only by:
//   - bytes marked `(Reserved)` on the S (timbre +0 MIDI ch, +1 B0-2 key
//     priority, 17-18 scale, +23/+28 velocity sense, vocoder +32-35 EG1);
//     the S ignores them — accessors here load and round-trip them but the
//     editor shows no control (see `EditorByteCoverage.reservedOnS`);
//   - renames (Step Length, Tempo Sync, Filter EG Int, AMP/Filter EG
//     reset) — cosmetic, reflected in the UI labels;
//   - a Param ID column (per-parameter live edit via SysEx 0x41, unused).
// Everything else is byte-identical to rev 1.4. Offsets below are transcribed
// from TABLEs 1 and 2 (and 5 for cross-references) and verified against the
// reference `.syx` dumps:
//
//   TABLE 1  program-level bytes   0..37        (+ 38..253 = timbre data)
//   TABLE 2  one timbre            +0..+51      (+52..+107 dummy/Reserved)
//            TIMBRE1 = base 38, TIMBRE2 = base 146  (38+107=145, 146+107=253)
//   TABLE 3  vocoder layout        38..141 (mode = Vocoder) — NOT this layout
//
// Offsets index the DECODED 254-byte buffer (after 7-to-8 bit unpacking),
// which is what `KorgSysEx.parse` returns.
//
// Verified encodings (checked empirically against the 128 factory patches):
//   - "64+/-N" params are offset-binary around 64 (tune, bend, transpose,
//     EG intensities, kbd track, panpot center 64, ...).
//   - Byte 36 (Swing, 0+/-100) and byte 37 (KBD Octave, -3..+3) are
//     two's-complement int8 — observed values 234 (= -22) and 253 (= -3).
//   - Byte 16 Voice Mode = (b >> 4) & 3: 0=Single, 2=Layer, 3=Vocoder
//     (value 1 unused). Verified: the 16 vocoder programs in the factory
//     bank are exactly the ones whose byte 57 falls outside 0..3.
//   - Tempo is a 16-bit big-endian at bytes 30/31 (20..300).
//   - In Vocoder mode the 38+ region switches to TABLE 3; callers must
//     check `voiceMode` before using timbre accessors.
public struct MicroKORGProgram: Codable, Equatable {

    /// The decoded program, always `KorgSysEx.programDataSize` (254) bytes.
    /// `internal(set)` so the TABLE 3 accessors in VocoderProgram.swift can
    /// write bytes; still read-only to code outside the Models module.
    public internal(set) var data: [UInt8]

    // MARK: Init

    public init?(data: [UInt8]) {
        guard data.count == KorgSysEx.programDataSize else { return nil }
        self.data = data
    }

    /// A zero-filled program (safe defaults: Single mode, all offsets valid).
    public static func blank() -> MicroKORGProgram {
        var program = MicroKORGProgram(data: [UInt8](repeating: 0, count: KorgSysEx.programDataSize))!
        program.setName("Init")
        program.data[16] = 0x40 // B6 set as in every factory dump; voice mode Single
        program.data[19] = 5    // default delay time base, per reference dump
        program.data[26] = 20   // EQ hi freq default
        program.data[28] = 15   // EQ low freq default
        program.data[31] = 120  // tempo LSB 120
        // Both timbres get the identical neutral-audible block: a Layer
        // patch must sound the same on T2 as on T1, and zero-filled bytes
        // mean full-negative (−63), not off (v12 §4).
        for base in [MicroKORGProgram.Timbre.one.base, MicroKORGProgram.Timbre.two.base] {
            program.data[base + 1] = 0x40  // assign mode = Poly
            program.data[base + 3] = 64    // tune center
            program.data[base + 4] = 66    // bend range +2
            program.data[base + 5] = 64    // transpose center
            program.data[base + 6] = 64    // vibrato intensity center
            program.data[base + 16] = 100  // osc1 level up — blank must be audible
            program.data[base + 20] = 127  // cutoff open
            program.data[base + 21] = 20   // resonance
            program.data[base + 22] = 64   // EG1 intensity center
            program.data[base + 23] = 64   // filter velocity sense neutral
            program.data[base + 24] = 64   // filter kbd track center
            program.data[base + 25] = 127  // amp level
            program.data[base + 26] = 64   // pan center
            program.data[base + 28] = 64   // velocity sense neutral
            program.data[base + 29] = 64   // kbd track neutral
            program.data[base + 31] = 64   // EG1 decay
            program.data[base + 32] = 127  // EG1 sustain
            program.data[base + 35] = 64   // EG2 decay
            program.data[base + 36] = 127  // EG2 sustain
            // PATCH intensities: zero would mean -63 (EG1→Pitch at full negative
            // drags pitch out of the audible range — the "silent JimBob" bug).
            program.data[base + 45] = 64
            program.data[base + 47] = 64
            program.data[base + 49] = 64
            program.data[base + 51] = 64
        }
        return program
    }

    /// Decode a complete SysEx message into a program.
    /// Accepts a `0x40` (current program) dump, or a `0x4C` bank dump
    /// (then `bankIndex` selects one of the 128 programs).
    public static func fromSysEx(_ message: [UInt8], bankIndex: Int = 0) throws -> MicroKORGProgram {
        let parsed = try KorgSysEx.parse(message)
        switch parsed.command {
        case .currentProgramDump:
            guard let program = MicroKORGProgram(data: parsed.data) else {
                throw KorgSysExError.wrongDataSize(
                    expected: KorgSysEx.programDataSize, got: parsed.data.count)
            }
            return program
        case .programDump:
            let slice = try KorgSysEx.program(bankIndex, inBank: parsed.data)
            guard let program = MicroKORGProgram(data: slice) else {
                throw KorgSysExError.wrongDataSize(
                    expected: KorgSysEx.programDataSize, got: slice.count)
            }
            return program
        default:
            throw KorgSysExError.unexpectedReply(
                expected: KorgSysEx.Command.currentProgramDump.rawValue,
                got: parsed.command.rawValue)
        }
    }

    // MARK: Bit helpers (internal so the TABLE 3 extension in VocoderProgram.swift can reuse them)

    func bits(_ offset: Int, shift: UInt8, mask: UInt8) -> UInt8 {
        (data[offset] >> shift) & mask
    }

    mutating func setBits(_ offset: Int, shift: UInt8, mask: UInt8, _ value: UInt8) {
        data[offset] = (data[offset] & ~(mask << shift)) | ((value & mask) << shift)
    }

    /// "64+/-N" offset-binary decode.
    static func signed64(_ byte: UInt8) -> Int { Int(byte) - 64 }

    /// "64+/-N" offset-binary encode.
    static func unsigned64(_ value: Int) -> UInt8 {
        UInt8(max(0, min(127, value + 64)))
    }

    /// Two's-complement int8 decode (Swing, KBD Octave).
    static func int8(_ byte: UInt8) -> Int { Int(Int8(bitPattern: byte)) }

    // MARK: TABLE 1 — program-level (bytes 0..37)

    /// Byte 0..11, ASCII, space padded.
    public var name: String { KorgSysEx.programName(from: data) }

    public mutating func setName(_ name: String) {
        KorgSysEx.setProgramName(name, in: &data)
    }

    public var voiceMode: VoiceMode {
        VoiceMode(rawValue: bits(16, shift: 4, mask: 3)) ?? .single
    }

    public mutating func setVoiceMode(_ mode: VoiceMode) {
        setBits(16, shift: 4, mask: 3, mode.rawValue)
    }

    // Arpeggio trigger control (bytes 14..15)
    /// 0..7 = 1..8 steps (byte 14, B0~2).
    public var triggerLength: UInt8 { data[14] & 0x07 }
    public mutating func setTriggerLength(_ v: UInt8) { setBits(14, shift: 0, mask: 0x07, v) }

    /// B0~7 = 1st..8th step, 1 = On (byte 15).
    public var triggerPattern: UInt8 { data[15] }
    public mutating func setTriggerPattern(_ v: UInt8) { data[15] = v }

    // Scale (byte 17)
    /// 0 = C (byte 17, B4~7).
    public var scaleKey: UInt8 { bits(17, shift: 4, mask: 0x0F) }
    public mutating func setScaleKey(_ v: UInt8) { setBits(17, shift: 4, mask: 0x0F, v) }

    /// 0 = Equal Temp (byte 17, B0~3).
    public var scaleType: UInt8 { bits(17, shift: 0, mask: 0x0F) }
    public mutating func setScaleType(_ v: UInt8) { setBits(17, shift: 0, mask: 0x0F, v) }

    // Delay FX (bytes 19..22)
    public var delaySync: Bool { data[19] >> 7 == 1 }
    public mutating func setDelaySync(_ on: Bool) { setBits(19, shift: 7, mask: 1, on ? 1 : 0) }

    /// 0..14 = 1/32..1/1 (*T-1). Only meaningful when `delaySync` is on.
    public var delayTimeBase: UInt8 { data[19] & 0x0F }
    public mutating func setDelayTimeBase(_ v: UInt8) { setBits(19, shift: 0, mask: 0x0F, v) }

    /// Delay time in ms when `delaySync` is off (0..127).
    public var delayTime: UInt8 { data[20] }
    public mutating func setDelayTime(_ v: UInt8) { data[20] = v }

    public var delayDepth: UInt8 { data[21] }
    public mutating func setDelayDepth(_ v: UInt8) { data[21] = v }

    public var delayType: DelayType { DelayType(rawValue: data[22]) ?? .stereo }
    public mutating func setDelayType(_ t: DelayType) { data[22] = t.rawValue }

    // Mod FX (bytes 23..25)
    public var modFxSpeed: UInt8 { data[23] }
    public mutating func setModFxSpeed(_ v: UInt8) { data[23] = v }

    public var modFxDepth: UInt8 { data[24] }
    public mutating func setModFxDepth(_ v: UInt8) { data[24] = v }

    public var modFxType: ModFxType { ModFxType(rawValue: data[25]) ?? .chorusFlange }
    public mutating func setModFxType(_ t: ModFxType) { data[25] = t.rawValue }

    // EQ (bytes 26..29)
    /// 0..29 = 1.00..18.0 kHz (*T-10).
    public var eqHiFreq: UInt8 { data[26] }
    public mutating func setEqHiFreq(_ v: UInt8) { data[26] = v }

    public var eqHiGain: Int { Self.signed64(data[27]) }
    public mutating func setEqHiGain(_ v: Int) { data[27] = Self.unsigned64(v) }

    /// 0..29 = 40..1000 Hz (*T-11).
    public var eqLowFreq: UInt8 { data[28] }
    public mutating func setEqLowFreq(_ v: UInt8) { data[28] = v }

    public var eqLowGain: Int { Self.signed64(data[29]) }
    public mutating func setEqLowGain(_ v: Int) { data[29] = Self.unsigned64(v) }

    // Arpeggiator (bytes 30..36)
    /// 16-bit big-endian tempo, 20..300 BPM (bytes 30 MSB / 31 LSB).
    public var arpTempo: Int { (Int(data[30]) << 8) | Int(data[31]) }

    public mutating func setArpTempo(_ bpm: Int) {
        let clamped = max(0, min(0xFFFF, bpm))
        data[30] = UInt8(clamped >> 8)
        data[31] = UInt8(clamped & 0xFF)
    }

    public var arpEnabled: Bool { data[32] >> 7 == 1 }
    public mutating func setArpEnabled(_ on: Bool) { setBits(32, shift: 7, mask: 1, on ? 1 : 0) }

    public var arpLatch: Bool { bits(32, shift: 6, mask: 1) == 1 }
    public mutating func setArpLatch(_ on: Bool) { setBits(32, shift: 6, mask: 1, on ? 1 : 0) }

    /// 0=Both, 1=Timbre1, 2=Timbre2.
    public var arpTarget: UInt8 { bits(32, shift: 4, mask: 3) }
    public mutating func setArpTarget(_ v: UInt8) { setBits(32, shift: 4, mask: 3, v) }

    public var arpKeySync: Bool { data[32] & 1 == 1 }
    public mutating func setArpKeySync(_ on: Bool) { setBits(32, shift: 0, mask: 1, on ? 1 : 0) }

    public var arpType: ArpType { ArpType(rawValue: data[33] & 0x0F) ?? .up }
    public mutating func setArpType(_ t: ArpType) { setBits(33, shift: 0, mask: 0x0F, t.rawValue) }

    /// 0..3 = 1..4 octaves.
    public var arpRange: UInt8 { bits(33, shift: 4, mask: 3) }
    public mutating func setArpRange(_ v: UInt8) { setBits(33, shift: 4, mask: 3, v) }

    /// Gate time, 0..100 %.
    public var arpGate: UInt8 { data[34] }
    public mutating func setArpGate(_ v: UInt8) { data[34] = v }

    /// 0..5 = 1/24, 1/16, 1/12, 1/8, 1/6, 1/4.
    public var arpResolution: UInt8 { data[35] }
    public mutating func setArpResolution(_ v: UInt8) { data[35] = v }

    /// Swing, -100..+100 (two's-complement int8).
    public var arpSwing: Int { Self.int8(data[36]) }
    public mutating func setArpSwing(_ v: Int) { data[36] = UInt8(bitPattern: Int8(max(-128, min(127, v)))) }

    // KBD Octave (byte 37), -3..+3 (two's-complement int8).
    public var kbdOctave: Int { Self.int8(data[37]) }
    public mutating func setKbdOctave(_ v: Int) { data[37] = UInt8(bitPattern: Int8(max(-3, min(3, v)))) }

    // MARK: TABLE 2 — timbre data (base 38 = Timbre1, base 146 = Timbre2)

    public enum Timbre: Int, CaseIterable {
        case one = 0
        case two = 1

        /// Absolute byte offset of this timbre's TABLE 2 block.
        public var base: Int { self == .one ? 38 : 146 }
    }

    /// Offset of a timbre block, or nil in Vocoder mode (TABLE 3 layout).
    private func base(_ t: Timbre) -> Int? {
        voiceMode == .vocoder ? nil : t.base
    }

    /// -1 (0xFF) = follow global MIDI channel.
    public func midiChannel(_ t: Timbre) -> UInt8? { base(t).map { data[$0] } }
    public mutating func setMidiChannel(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b] = v
    }

    public func assignMode(_ t: Timbre) -> UInt8? { base(t).map { bits($0 + 1, shift: 6, mask: 3) } }
    public mutating func setAssignMode(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        setBits(b + 1, shift: 6, mask: 3, v)
    }

    /// +1 B5. EG2 restarts on note-on.
    public func eg2Reset(_ t: Timbre) -> Bool? { base(t).map { self.bits($0 + 1, shift: 5, mask: 1) == 1 } }
    public mutating func setEg2Reset(_ on: Bool, _ t: Timbre) {
        guard let b = base(t) else { return }
        setBits(b + 1, shift: 5, mask: 1, on ? 1 : 0)
    }

    /// +1 B4. EG1 restarts on note-on.
    public func eg1Reset(_ t: Timbre) -> Bool? { base(t).map { self.bits($0 + 1, shift: 4, mask: 1) == 1 } }
    public mutating func setEg1Reset(_ on: Bool, _ t: Timbre) {
        guard let b = base(t) else { return }
        setBits(b + 1, shift: 4, mask: 1, on ? 1 : 0)
    }

    /// +1 B3, 0/1 = Single/Multi (Mono/Unison modes).
    public func triggerMode(_ t: Timbre) -> Bool? { base(t).map { self.bits($0 + 1, shift: 3, mask: 1) == 1 } }
    public mutating func setTriggerMode(_ multi: Bool, _ t: Timbre) {
        guard let b = base(t) else { return }
        setBits(b + 1, shift: 3, mask: 1, multi ? 1 : 0)
    }

    /// +1 B0~1, 0 = Last.
    public func keyPriority(_ t: Timbre) -> UInt8? { base(t).map { bits($0 + 1, shift: 0, mask: 3) } }
    public mutating func setKeyPriority(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        setBits(b + 1, shift: 0, mask: 3, v)
    }

    public func unisonDetune(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 2] } }
    public mutating func setUnisonDetune(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 2] = v
    }

    // PITCH (+3..+6)
    public func tune(_ t: Timbre) -> Int? { base(t).map { Self.signed64(data[$0 + 3]) } }         // -50..+50 cents
    public mutating func setTune(_ v: Int, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 3] = Self.unsigned64(v)
    }

    public func bendRange(_ t: Timbre) -> Int? { base(t).map { Self.signed64(data[$0 + 4]) } }     // -12..+12
    public mutating func setBendRange(_ v: Int, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 4] = Self.unsigned64(v)
    }

    public func transpose(_ t: Timbre) -> Int? { base(t).map { Self.signed64(data[$0 + 5]) } }     // -24..+24
    public mutating func setTranspose(_ v: Int, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 5] = Self.unsigned64(v)
    }

    public func vibratoIntensity(_ t: Timbre) -> Int? { base(t).map { Self.signed64(data[$0 + 6]) } }
    public mutating func setVibratoIntensity(_ v: Int, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 6] = Self.unsigned64(v)
    }

    public mutating func setPortamento(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 15] = v & 0x7F
    }


    // OSC1 (+7..+10)
    public func osc1Wave(_ t: Timbre) -> Osc1Wave? {
        base(t).flatMap { Osc1Wave(rawValue: data[$0 + 7]) }
    }
    public mutating func setOsc1Wave(_ v: Osc1Wave, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 7] = v.rawValue
    }

    public func osc1Control1(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 8] } }
    public func osc1Control2(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 9] } }
    public mutating func setOsc1Control1(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 8] = v
    }
    public mutating func setOsc1Control2(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 9] = v
    }

    /// DWGS wave number 0..63 (only when `osc1Wave == .dwgs`).
    public func dwgsWave(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 10] } }
    public mutating func setDwgsWave(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 10] = v
    }

    // OSC2 (+12..+14)
    public func osc2Wave(_ t: Timbre) -> Osc2Wave? {
        base(t).flatMap { Osc2Wave(rawValue: data[$0 + 12] & 0x03) }
    }
    public mutating func setOsc2Wave(_ v: Osc2Wave, _ t: Timbre) {
        guard let b = base(t) else { return }
        setBits(b + 12, shift: 0, mask: 0x03, v.rawValue)
    }

    public func osc2Mod(_ t: Timbre) -> Osc2Mod? {
        base(t).flatMap { Osc2Mod(rawValue: data[$0 + 12] >> 4 & 0x03) }
    }
    public mutating func setOsc2Mod(_ v: Osc2Mod, _ t: Timbre) {
        guard let b = base(t) else { return }
        setBits(b + 12, shift: 4, mask: 0x03, v.rawValue)
    }

    public func osc2Semitone(_ t: Timbre) -> Int? { base(t).map { Self.signed64(data[$0 + 13]) } }  // -24..+24
    public mutating func setOsc2Semitone(_ v: Int, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 13] = Self.unsigned64(v)
    }

    public func osc2Tune(_ t: Timbre) -> Int? { base(t).map { Self.signed64(data[$0 + 14]) } }      // -63..+63
    public mutating func setOsc2Tune(_ v: Int, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 14] = Self.unsigned64(v)
    }

    /// Portamento time, 0..127 (+15, bit 7 unused).
    public func portamento(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 15] & 0x7F } }

    // MIXER (+16..+18)
    public func osc1Level(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 16] } }
    public func osc2Level(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 17] } }
    public func noiseLevel(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 18] } }
    public mutating func setOsc1Level(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 16] = v
    }
    public mutating func setOsc2Level(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 17] = v
    }
    public mutating func setNoiseLevel(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 18] = v
    }

    // FILTER (+19..+24)
    public func filterType(_ t: Timbre) -> FilterType? {
        base(t).flatMap { FilterType(rawValue: data[$0 + 19]) }
    }
    public mutating func setFilterType(_ v: FilterType, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 19] = v.rawValue
    }

    public func filterCutoff(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 20] } }
    public mutating func setFilterCutoff(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 20] = v
    }

    public func filterResonance(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 21] } }
    public mutating func setFilterResonance(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 21] = v
    }

    /// EG1 intensity into filter, -63..+63 (+22).
    public func filterEG1Intensity(_ t: Timbre) -> Int? { base(t).map { Self.signed64(data[$0 + 22]) } }
    public mutating func setFilterEG1Intensity(_ v: Int, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 22] = Self.unsigned64(v)
    }

    public func filterKeyboardTrack(_ t: Timbre) -> Int? { base(t).map { Self.signed64(data[$0 + 24]) } }
    public mutating func setFilterKeyboardTrack(_ v: Int, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 24] = Self.unsigned64(v)
    }

    /// Filter velocity sense, 64 = 0 (+23).
    public func filterVelocitySense(_ t: Timbre) -> Int? {
        base(t).map { Self.signed64(data[$0 + 23]) }
    }
    public mutating func setFilterVelocitySense(_ v: Int, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 23] = Self.unsigned64(v)
    }

    // AMP (+25..+29)
    public func ampLevel(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 25] } }
    public mutating func setAmpLevel(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 25] = v
    }

    /// Panpot, 0..127 (64 = center) (+26).
    public func panpot(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 26] } }
    public mutating func setPanpot(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 26] = v
    }

    /// (+27 bit 0). The amp EG switch (+27 bit 6) is dead on the S — the
    /// S chart marks +27 B1-7 "not use"; only B0 Distortion survives.
    public func distortion(_ t: Timbre) -> Bool? { base(t).map { data[$0 + 27] & 1 == 1 } }
    public mutating func setDistortion(_ on: Bool, _ t: Timbre) {
        guard let b = base(t) else { return }
        if on { data[b + 27] |= 1 } else { data[b + 27] &= ~1 }
    }

    /// Amp velocity sense, 64 = 0 (+28).
    public func ampVelocitySense(_ t: Timbre) -> Int? {
        base(t).map { Self.signed64(data[$0 + 28]) }
    }
    public mutating func setAmpVelocitySense(_ v: Int, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 28] = Self.unsigned64(v)
    }

    /// Amp keyboard track, 64 +/-63 = 0 +/-63 (+29).
    public func ampKeyboardTrack(_ t: Timbre) -> Int? {
        base(t).map { Self.signed64(data[$0 + 29]) }
    }
    public mutating func setAmpKeyboardTrack(_ v: Int, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 29] = Self.unsigned64(v)
    }

    // EG1 = filter envelope (+30..+33); EG2 = amp envelope (+34..+37)
    public func eg1Attack(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 30] } }
    public func eg1Decay(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 31] } }
    public func eg1Sustain(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 32] } }
    public func eg1Release(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 33] } }
    public func eg2Attack(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 34] } }
    public func eg2Decay(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 35] } }
    public func eg2Sustain(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 36] } }
    public func eg2Release(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 37] } }

    public mutating func setEg1Attack(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 30] = v
    }
    public mutating func setEg1Decay(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 31] = v
    }
    public mutating func setEg1Sustain(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 32] = v
    }
    public mutating func setEg1Release(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 33] = v
    }
    public mutating func setEg2Attack(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 34] = v
    }
    public mutating func setEg2Decay(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 35] = v
    }
    public mutating func setEg2Sustain(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 36] = v
    }
    public mutating func setEg2Release(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 37] = v
    }

    // LFO1 (+38..+40), LFO2 (+41..+43)
    public func lfo1Wave(_ t: Timbre) -> LFO1Wave? {
        base(t).flatMap { LFO1Wave(rawValue: data[$0 + 38] & 0x03) }
    }
    public mutating func setLfo1Wave(_ v: LFO1Wave, _ t: Timbre) {
        guard let b = base(t) else { return }
        setBits(b + 38, shift: 0, mask: 0x03, v.rawValue)
    }

    public func lfo1Frequency(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 39] } }
    public mutating func setLfo1Frequency(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 39] = v
    }

    public func lfo1TempoSync(_ t: Timbre) -> Bool? { base(t).map { data[$0 + 40] >> 7 == 1 } }
    public mutating func setLfo1TempoSync(_ on: Bool, _ t: Timbre) {
        guard let b = base(t) else { return }
        setBits(b + 40, shift: 7, mask: 1, on ? 1 : 0)
    }

    /// +40 B0~4, 0..14 = 1/1..1/32 (*T-5). Meaningful when Tempo Sync is on.
    public func lfo1SyncNote(_ t: Timbre) -> UInt8? { base(t).map { bits($0 + 40, shift: 0, mask: 0x1F) } }
    public mutating func setLfo1SyncNote(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        setBits(b + 40, shift: 0, mask: 0x1F, v)
    }

    /// +38 B4~5, 0..2 = OFF/Timbre/Voice.
    public func lfo1KeySync(_ t: Timbre) -> UInt8? { base(t).map { bits($0 + 38, shift: 4, mask: 3) } }
    public mutating func setLfo1KeySync(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        setBits(b + 38, shift: 4, mask: 3, v)
    }

    public func lfo2Wave(_ t: Timbre) -> LFO2Wave? {
        base(t).flatMap { LFO2Wave(rawValue: data[$0 + 41] & 0x03) }
    }
    public mutating func setLfo2Wave(_ v: LFO2Wave, _ t: Timbre) {
        guard let b = base(t) else { return }
        setBits(b + 41, shift: 0, mask: 0x03, v.rawValue)
    }

    public func lfo2Frequency(_ t: Timbre) -> UInt8? { base(t).map { data[$0 + 42] } }
    public mutating func setLfo2Frequency(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        data[b + 42] = v
    }

    public func lfo2TempoSync(_ t: Timbre) -> Bool? { base(t).map { data[$0 + 43] >> 7 == 1 } }
    public mutating func setLfo2TempoSync(_ on: Bool, _ t: Timbre) {
        guard let b = base(t) else { return }
        setBits(b + 43, shift: 7, mask: 1, on ? 1 : 0)
    }

    /// +43 B0~4, 0..14 = 1/1..1/32 (*T-5).
    public func lfo2SyncNote(_ t: Timbre) -> UInt8? { base(t).map { bits($0 + 43, shift: 0, mask: 0x1F) } }
    public mutating func setLfo2SyncNote(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        setBits(b + 43, shift: 0, mask: 0x1F, v)
    }

    /// +41 B4~5, 0..2 = OFF/Timbre/Voice.
    public func lfo2KeySync(_ t: Timbre) -> UInt8? { base(t).map { bits($0 + 41, shift: 4, mask: 3) } }
    public mutating func setLfo2KeySync(_ v: UInt8, _ t: Timbre) {
        guard let b = base(t) else { return }
        setBits(b + 41, shift: 4, mask: 3, v)
    }

    // PATCH 1..4 (+44..+51): pairs of (destination<<4 | source) + intensity
    public func patchSource(_ index: Int, _ t: Timbre) -> PatchSource? {
        guard (0..<4).contains(index) else { return nil }
        return base(t).flatMap { PatchSource(rawValue: data[$0 + 44 + index * 2] & 0x0F) }
    }

    public func patchDestination(_ index: Int, _ t: Timbre) -> PatchDestination? {
        guard (0..<4).contains(index) else { return nil }
        return base(t).flatMap { PatchDestination(rawValue: data[$0 + 44 + index * 2] >> 4) }
    }

    public func patchIntensity(_ index: Int, _ t: Timbre) -> Int? {
        guard (0..<4).contains(index) else { return nil }
        return base(t).map { Self.signed64(data[$0 + 45 + index * 2]) }
    }

    public mutating func setPatchSource(_ index: Int, _ v: PatchSource, _ t: Timbre) {
        guard (0..<4).contains(index), let b = base(t) else { return }
        setBits(b + 44 + index * 2, shift: 0, mask: 0x0F, v.rawValue)
    }

    public mutating func setPatchDestination(_ index: Int, _ v: PatchDestination, _ t: Timbre) {
        guard (0..<4).contains(index), let b = base(t) else { return }
        setBits(b + 44 + index * 2, shift: 4, mask: 0x0F, v.rawValue)
    }

    public mutating func setPatchIntensity(_ index: Int, _ v: Int, _ t: Timbre) {
        guard (0..<4).contains(index), let b = base(t) else { return }
        data[b + 45 + index * 2] = Self.unsigned64(v)
    }
}

// MARK: - Enums (values per the chart's lookup tables)

/// TABLE 1 byte 16, bits 4-5. Value 1 is unused by the instrument.
public enum VoiceMode: UInt8, CaseIterable, Codable, Hashable {
    case single = 0
    case layer = 2
    case vocoder = 3

    public var label: String {
        switch self {
        case .single: return "Single"
        case .layer: return "Layer"
        case .vocoder: return "Vocoder"
        }
    }
}

/// OSC1 wave, TABLE 2 +7, lookup *T-2.
public enum Osc1Wave: UInt8, CaseIterable, Codable, Hashable {
    case saw = 0
    case pulse = 1
    case tri = 2
    case sinCross = 3
    case voxWave = 4
    case dwgs = 5
    case noise = 6
    case audioIn = 7

    public var label: String {
        switch self {
        case .saw: return "Saw"
        case .pulse: return "Pulse"
        case .tri: return "Tri"
        case .sinCross: return "Sin (Cross)"
        case .voxWave: return "Vox Wave"
        case .dwgs: return "DWGS"
        case .noise: return "Noise"
        case .audioIn: return "Audio In"
        }
    }
}

/// OSC2 wave, TABLE 2 +12 bits 0-1.
public enum Osc2Wave: UInt8, CaseIterable, Codable, Hashable {
    case saw = 0
    case squ = 1
    case tri = 2

    public var label: String {
        switch self {
        case .saw: return "Saw"
        case .squ: return "Square"
        case .tri: return "Tri"
        }
    }
}

/// OSC2 modulation select, TABLE 2 +12 bits 4-5.
public enum Osc2Mod: UInt8, CaseIterable, Codable, Hashable {
    case off = 0
    case ring = 1
    case sync = 2
    case ringSync = 3

    public var label: String {
        switch self {
        case .off: return "Off"
        case .ring: return "Ring"
        case .sync: return "Sync"
        case .ringSync: return "Ring+Sync"
        }
    }
}

/// Filter type, TABLE 2 +19.
public enum FilterType: UInt8, CaseIterable, Codable, Hashable {
    case lp24 = 0
    case lp12 = 1
    case bp12 = 2
    case hp12 = 3

    public var label: String {
        switch self {
        case .lp24: return "24LPF"
        case .lp12: return "12LPF"
        case .bp12: return "12BPF"
        case .hp12: return "12HPF"
        }
    }
}

/// LFO1 wave, TABLE 2 +38 bits 0-1.
public enum LFO1Wave: UInt8, CaseIterable, Codable, Hashable {
    case saw = 0
    case squ = 1
    case tri = 2
    case sAndH = 3

    public var label: String {
        switch self {
        case .saw: return "Saw"
        case .squ: return "Squ"
        case .tri: return "Tri"
        case .sAndH: return "S/H"
        }
    }
}

/// LFO2 wave, TABLE 2 +41 bits 0-1.
public enum LFO2Wave: UInt8, CaseIterable, Codable, Hashable {
    case saw = 0
    case squPositive = 1
    case sin = 2
    case sAndH = 3

    public var label: String {
        switch self {
        case .saw: return "Saw"
        case .squPositive: return "Squ(+)"
        case .sin: return "Sin"
        case .sAndH: return "S/H"
        }
    }
}

/// Arpeggiator type, TABLE 1 byte 33, lookup *T-12.
public enum ArpType: UInt8, CaseIterable, Codable, Hashable {
    case up = 0
    case down = 1
    case alt1 = 2
    case alt2 = 3
    case random = 4
    case trigger = 5

    public var label: String {
        switch self {
        case .up: return "Up"
        case .down: return "Down"
        case .alt1: return "Alt1"
        case .alt2: return "Alt2"
        case .random: return "Random"
        case .trigger: return "Trigger"
        }
    }
}

/// Delay FX type, TABLE 1 byte 22.
public enum DelayType: UInt8, CaseIterable, Codable, Hashable {
    case stereo = 0
    case cross = 1
    case lr = 2

    public var label: String {
        switch self {
        case .stereo: return "Stereo Delay"
        case .cross: return "Cross Delay"
        case .lr: return "L/R Delay"
        }
    }
}

/// Mod FX type, TABLE 1 byte 25.
public enum ModFxType: UInt8, CaseIterable, Codable, Hashable {
    case chorusFlange = 0
    case ensemble = 1
    case phaser = 2

    public var label: String {
        switch self {
        case .chorusFlange: return "Cho/Flg"
        case .ensemble: return "Ensemble"
        case .phaser: return "Phaser"
        }
    }
}

/// Patch modulation source, TABLE 2 +44 bits 0-3, lookup *T-3.
public enum PatchSource: UInt8, CaseIterable, Codable, Hashable {
    case eg1 = 0
    case eg2 = 1
    case lfo1 = 2
    case lfo2 = 3
    case velocity = 4
    case kbdTrack = 5
    case midi1 = 6 // P.Bend
    case midi2 = 7 // Mod

    /// Lookup *T-3.
    public var label: String {
        switch self {
        case .eg1: return "EG 1"
        case .eg2: return "EG 2"
        case .lfo1: return "LFO 1"
        case .lfo2: return "LFO 2"
        case .velocity: return "Velocity"
        case .kbdTrack: return "KBD Track"
        case .midi1: return "P.Bend"
        case .midi2: return "Mod"
        }
    }
}

/// Patch modulation destination, TABLE 2 +44 bits 4-7, lookup *T-4.
public enum PatchDestination: UInt8, CaseIterable, Codable, Hashable {
    case pitch = 0
    case osc2Pitch = 1
    case osc1Control1 = 2
    case noiseLevel = 3
    case cutoff = 4
    case amp = 5
    case pan = 6
    case lfo2Freq = 7

    public var label: String {
        switch self {
        case .pitch: return "Pitch"
        case .osc2Pitch: return "Osc2 Pitch"
        case .osc1Control1: return "Osc1 CTRL1"
        case .noiseLevel: return "Noise Level"
        case .cutoff: return "Cutoff"
        case .amp: return "Amp"
        case .pan: return "Pan"
        case .lfo2Freq: return "LFO2 Freq"
        }
    }
}
