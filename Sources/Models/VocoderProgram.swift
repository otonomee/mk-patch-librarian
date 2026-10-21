import Foundation
import PBAPI

// MARK: - TABLE 3 : VOCODER PARAMETER
//
// Layout per the microKORG S chart (rev 1.01, TABLE 3 — identical to the
// original microKORG chart rev 1.4 apart from rows the S marks Reserved:
// +0 MIDI ch, +1 B4 EG1 reset, +1 B0-2 key priority, +32-35 EG1). Program
// data layout in Vocoder mode:
//
//   38~179   VOCODER DATA   (TABLE 3, offsets +0..+141)
//   180~253  (dummy bytes)  -- zero in every factory vocoder program
//
// CHART TYPO NOTE: the program-structure table (both charts, "38~141 VOCODER
// DATA / 142~253 dummy") is wrong. The chart's own TABLE 3 line
// "+78~141 E.F Hold [0]~[15]" is RELATIVE to +38, and the microKORG's own
// factory bank confirms: the 16 four-byte hold levels occupy absolute
// 116..179 (38+78 .. 38+141), every one with low byte 00, and bytes
// 180..253 are all zero. Accessors below index absolute bytes.
//
// Mirrors the style of the TABLE 1/2 accessors in MicroKORGProgram.swift:
// every accessor returns nil unless `voiceMode == .vocoder`, so callers can
// never mix the two layouts. Offsets below are relative to `vocoderBase` (38)
// and index the DECODED 254-byte buffer.
//
// Verified empirically against the 16 vocoder programs in the microKORG's
// factory bank (`microkorg-voice-bank.syx`) — see VocoderProgramTests.
extension MicroKORGProgram {

    /// Absolute offset of the TABLE 3 block, and its LAST byte (38 + 141).
    public static let vocoderBase = 38
    public static let vocoderLast = 179
    /// Bytes 180..253 are dummy in Vocoder mode (all zero in the factory bank).
    public static let vocoderDummyStart = 180

    /// TABLE 3 base, or nil when the program is not in Vocoder mode.
    private var vb: Int? { voiceMode == .vocoder ? Self.vocoderBase : nil }

    // MARK: Header (+0..+2)

    /// -1 (0xFF) = follow global MIDI channel.
    public func vocoderMidiChannel() -> UInt8? { vb.map { data[$0] } }
    public mutating func setVocoderMidiChannel(_ v: UInt8) {
        guard let b = vb else { return }
        data[b] = v
    }

    /// Bits 6-7 of +1 (0,1,2 = Mono,Poly,Unison); the same bitfield as TABLE 2.
    public func vocoderAssignMode() -> UInt8? { vb.map { bits($0 + 1, shift: 6, mask: 3) } }
    public mutating func setVocoderAssignMode(_ v: UInt8) {
        guard let b = vb else { return }
        setBits(b + 1, shift: 6, mask: 3, v)
    }

    public func vocoderUnisonDetune() -> UInt8? { vb.map { data[$0 + 2] } }
    public mutating func setVocoderUnisonDetune(_ v: UInt8) {
        guard let b = vb else { return }
        data[b + 2] = v
    }

    // MARK: PITCH (+3..+6) — encodings identical to TABLE 2

    public func vocoderTune() -> Int? { vb.map { Self.signed64(data[$0 + 3]) } }          // -50..+50 cent
    public mutating func setVocoderTune(_ v: Int) {
        guard let b = vb else { return }
        data[b + 3] = Self.unsigned64(v)
    }

    public func vocoderBendRange() -> Int? { vb.map { Self.signed64(data[$0 + 4]) } }      // -12..+12
    public mutating func setVocoderBendRange(_ v: Int) {
        guard let b = vb else { return }
        data[b + 4] = Self.unsigned64(v)
    }

    public func vocoderTranspose() -> Int? { vb.map { Self.signed64(data[$0 + 5]) } }      // -24..+24
    public mutating func setVocoderTranspose(_ v: Int) {
        guard let b = vb else { return }
        data[b + 5] = Self.unsigned64(v)
    }

    public func vocoderVibratoIntensity() -> Int? { vb.map { Self.signed64(data[$0 + 6]) } }  // -63..+63
    public mutating func setVocoderVibratoIntensity(_ v: Int) {
        guard let b = vb else { return }
        data[b + 6] = Self.unsigned64(v)
    }

    // MARK: OSC (+7..+10) — a single oscillator, same *T-2 wave table

    public func vocoderOscWave() -> Osc1Wave? { vb.flatMap { Osc1Wave(rawValue: data[$0 + 7]) } }
    public mutating func setVocoderOscWave(_ v: Osc1Wave) {
        guard let b = vb else { return }
        data[b + 7] = v.rawValue
    }

    public func vocoderOscControl1() -> UInt8? { vb.map { data[$0 + 8] } }
    public mutating func setVocoderOscControl1(_ v: UInt8) {
        guard let b = vb else { return }
        data[b + 8] = v
    }

    public func vocoderOscControl2() -> UInt8? { vb.map { data[$0 + 9] } }
    public mutating func setVocoderOscControl2(_ v: UInt8) {
        guard let b = vb else { return }
        data[b + 9] = v
    }

    /// DWGS wave number 0..63 (when `vocoderOscWave == .dwgs`).
    public func vocoderDwgsWave() -> UInt8? { vb.map { data[$0 + 10] } }
    public mutating func setVocoderDwgsWave(_ v: UInt8) {
        guard let b = vb else { return }
        data[b + 10] = v
    }

    // MARK: AUDIO IN1 (+12, +18..+20) — voice input & envelope follower

    /// +12 bit 0: enable the high-pass gate on audio input 1.
    public func vocoderHpfGate() -> Bool? { vb.map { data[$0 + 12] & 1 == 1 } }
    public mutating func setVocoderHpfGate(_ on: Bool) {
        guard let b = vb else { return }
        setBits(b + 12, shift: 0, mask: 1, on ? 1 : 0)
    }

    public func vocoderHpfLevel() -> UInt8? { vb.map { data[$0 + 18] } }
    public mutating func setVocoderHpfLevel(_ v: UInt8) {
        guard let b = vb else { return }
        data[b + 18] = v
    }

    public func vocoderGateSense() -> UInt8? { vb.map { data[$0 + 19] } }
    public mutating func setVocoderGateSense(_ v: UInt8) {
        guard let b = vb else { return }
        data[b + 19] = v
    }

    public func vocoderThreshold() -> UInt8? { vb.map { data[$0 + 20] } }
    public mutating func setVocoderThreshold(_ v: UInt8) {
        guard let b = vb else { return }
        data[b + 20] = v
    }

    // MARK: PITCH (2) + MIXER (+14..+17)

    /// Portamento time, 0..127 (+14 bits 0-6).
    public func vocoderPortamento() -> UInt8? { vb.map { data[$0 + 14] & 0x7F } }
    public mutating func setVocoderPortamento(_ v: UInt8) {
        guard let b = vb else { return }
        setBits(b + 14, shift: 0, mask: 0x7F, v)
    }

    public func vocoderOscLevel() -> UInt8? { vb.map { data[$0 + 15] } }
    public mutating func setVocoderOscLevel(_ v: UInt8) {
        guard let b = vb else { return }
        data[b + 15] = v
    }

    /// Synth-engine ("external") level — the oscillator part mixed against the voice.
    public func vocoderExtLevel() -> UInt8? { vb.map { data[$0 + 16] } }
    public mutating func setVocoderExtLevel(_ v: UInt8) {
        guard let b = vb else { return }
        data[b + 16] = v
    }

    public func vocoderNoiseLevel() -> UInt8? { vb.map { data[$0 + 17] } }
    public mutating func setVocoderNoiseLevel(_ v: UInt8) {
        guard let b = vb else { return }
        data[b + 17] = v
    }

    // MARK: FILTER (+21..+26) — no filter *type* in vocoder mode

    public func vocoderFilterShift() -> VocoderFilterShift? {
        vb.flatMap { VocoderFilterShift(rawValue: data[$0 + 21]) }
    }
    public mutating func setVocoderFilterShift(_ v: VocoderFilterShift) {
        guard let b = vb else { return }
        data[b + 21] = v.rawValue
    }

    public func vocoderFilterCutoff() -> Int? { vb.map { Self.signed64(data[$0 + 22]) } }   // -63..+63
    public mutating func setVocoderFilterCutoff(_ v: Int) {
        guard let b = vb else { return }
        data[b + 22] = Self.unsigned64(v)
    }

    public func vocoderFilterResonance() -> UInt8? { vb.map { data[$0 + 23] } }
    public mutating func setVocoderFilterResonance(_ v: UInt8) {
        guard let b = vb else { return }
        data[b + 23] = v
    }

    public func vocoderFilterModSource() -> VocoderFilterModSource? {
        vb.flatMap { VocoderFilterModSource(rawValue: data[$0 + 24]) }
    }
    public mutating func setVocoderFilterModSource(_ v: VocoderFilterModSource) {
        guard let b = vb else { return }
        data[b + 24] = v.rawValue
    }

    public func vocoderFilterIntensity() -> Int? { vb.map { Self.signed64(data[$0 + 25]) } } // -63..+63
    public mutating func setVocoderFilterIntensity(_ v: Int) {
        guard let b = vb else { return }
        data[b + 25] = Self.unsigned64(v)
    }

    /// Envelope-follower sense, 0..126; 127 = Hold (then TABLE 4 levels apply).
    public func vocoderEfSense() -> UInt8? { vb.map { data[$0 + 26] } }
    public mutating func setVocoderEfSense(_ v: UInt8) {
        guard let b = vb else { return }
        data[b + 26] = min(v, 127)
    }

    public func vocoderEfSenseIsHold() -> Bool { vocoderEfSense() == 127 }

    // MARK: AMP (+27..+31)

    public func vocoderAmpLevel() -> UInt8? { vb.map { data[$0 + 27] } }
    public mutating func setVocoderAmpLevel(_ v: UInt8) {
        guard let b = vb else { return }
        data[b + 27] = v
    }

    public func vocoderDirectLevel() -> UInt8? { vb.map { data[$0 + 28] } }
    public mutating func setVocoderDirectLevel(_ v: UInt8) {
        guard let b = vb else { return }
        data[b + 28] = v
    }

    /// +29 bit 0.
    public func vocoderDistortion() -> Bool? { vb.map { data[$0 + 29] & 1 == 1 } }
    public mutating func setVocoderDistortion(_ on: Bool) {
        guard let b = vb else { return }
        setBits(b + 29, shift: 0, mask: 1, on ? 1 : 0)
    }

    public func vocoderVelSense() -> Int? { vb.map { Self.signed64(data[$0 + 30]) } }        // 64 = 0
    public mutating func setVocoderVelSense(_ v: Int) {
        guard let b = vb else { return }
        data[b + 30] = Self.unsigned64(v)
    }

    public func vocoderKeyTrack() -> Int? { vb.map { Self.signed64(data[$0 + 31]) } }        // -63..+63
    public mutating func setVocoderKeyTrack(_ v: Int) {
        guard let b = vb else { return }
        data[b + 31] = Self.unsigned64(v)
    }

    // MARK: EG1 (+32..+35) — chart fixes these at 0/0/127/0; read-only.

    public func vocoderEg1Attack() -> UInt8? { vb.map { data[$0 + 32] } }
    public func vocoderEg1Decay() -> UInt8? { vb.map { data[$0 + 33] } }
    public func vocoderEg1Sustain() -> UInt8? { vb.map { data[$0 + 34] } }
    public func vocoderEg1Release() -> UInt8? { vb.map { data[$0 + 35] } }

    // MARK: EG2 (+36..+39) — the amp envelope; fully editable 0..127.

    public func vocoderEg2Attack() -> UInt8? { vb.map { data[$0 + 36] } }
    public mutating func setVocoderEg2Attack(_ v: UInt8) {
        guard let b = vb else { return }
        data[b + 36] = v
    }

    public func vocoderEg2Decay() -> UInt8? { vb.map { data[$0 + 37] } }
    public mutating func setVocoderEg2Decay(_ v: UInt8) {
        guard let b = vb else { return }
        data[b + 37] = v
    }

    public func vocoderEg2Sustain() -> UInt8? { vb.map { data[$0 + 38] } }
    public mutating func setVocoderEg2Sustain(_ v: UInt8) {
        guard let b = vb else { return }
        data[b + 38] = v
    }

    public func vocoderEg2Release() -> UInt8? { vb.map { data[$0 + 39] } }
    public mutating func setVocoderEg2Release(_ v: UInt8) {
        guard let b = vb else { return }
        data[b + 39] = v
    }

    // MARK: LFO1 (+40..+42), LFO2 (+43..+45)
    // Same encodings as TABLE 2's LFOs; wave keys follow *T-5 / *T-2 tables.

    public func vocoderLfo1Wave() -> LFO1Wave? { vb.flatMap { LFO1Wave(rawValue: data[$0 + 40] & 0x03) } }
    public mutating func setVocoderLfo1Wave(_ v: LFO1Wave) {
        guard let b = vb else { return }
        setBits(b + 40, shift: 0, mask: 0x03, v.rawValue)
    }

    /// +40 bits 4-5: 0..2 = OFF, Timbre, Voice.
    public func vocoderLfo1KeySync() -> UInt8? { vb.map { bits($0 + 40, shift: 4, mask: 3) } }

    public func vocoderLfo1Frequency() -> UInt8? { vb.map { data[$0 + 41] } }
    public mutating func setVocoderLfo1Frequency(_ v: UInt8) {
        guard let b = vb else { return }
        data[b + 41] = v
    }

    public func vocoderLfo1TempoSync() -> Bool? { vb.map { data[$0 + 42] >> 7 == 1 } }
    public mutating func setVocoderLfo1TempoSync(_ on: Bool) {
        guard let b = vb else { return }
        setBits(b + 42, shift: 7, mask: 1, on ? 1 : 0)
    }

    /// Sync note 0..14 = 1/1..1/32 (*T-5), +42 bits 0-4.
    public func vocoderLfo1SyncNote() -> UInt8? { vb.map { data[$0 + 42] & 0x1F } }
    public mutating func setVocoderLfo1SyncNote(_ v: UInt8) {
        guard let b = vb else { return }
        setBits(b + 42, shift: 0, mask: 0x1F, v)
    }

    public func vocoderLfo2Wave() -> LFO2Wave? { vb.flatMap { LFO2Wave(rawValue: data[$0 + 43] & 0x03) } }
    public mutating func setVocoderLfo2Wave(_ v: LFO2Wave) {
        guard let b = vb else { return }
        setBits(b + 43, shift: 0, mask: 0x03, v.rawValue)
    }

    public func vocoderLfo2KeySync() -> UInt8? { vb.map { bits($0 + 43, shift: 4, mask: 3) } }

    public func vocoderLfo2Frequency() -> UInt8? { vb.map { data[$0 + 44] } }
    public mutating func setVocoderLfo2Frequency(_ v: UInt8) {
        guard let b = vb else { return }
        data[b + 44] = v
    }

    public func vocoderLfo2TempoSync() -> Bool? { vb.map { data[$0 + 45] >> 7 == 1 } }
    public mutating func setVocoderLfo2TempoSync(_ on: Bool) {
        guard let b = vb else { return }
        setBits(b + 45, shift: 7, mask: 1, on ? 1 : 0)
    }

    public func vocoderLfo2SyncNote() -> UInt8? { vb.map { data[$0 + 45] & 0x1F } }
    public mutating func setVocoderLfo2SyncNote(_ v: UInt8) {
        guard let b = vb else { return }
        setBits(b + 45, shift: 0, mask: 0x1F, v)
    }

    // MARK: BAND LEVELS (+46..+61) and BAND PANS (+62..+77)
    //
    // 16 stored entries, in duplicated pairs: CH LEVEL [0]=[1]=BAND[1] LEVEL,
    // [2]=[3]=BAND[2] ... so 8 vocoder bands. Reads take the even entry;
    // writes fill both halves so the synth's view stays consistent.

    public static let vocoderBandCount = 8

    /// Band 0..7 level, 0..127.
    public func vocoderBandLevel(_ band: Int) -> UInt8? {
        guard (0..<Self.vocoderBandCount).contains(band) else { return nil }
        return vb.map { data[$0 + 46 + band * 2] }
    }

    public mutating func setVocoderBandLevel(_ v: UInt8, _ band: Int) {
        guard let b = vb, (0..<Self.vocoderBandCount).contains(band) else { return }
        data[b + 46 + band * 2] = v
        data[b + 46 + band * 2 + 1] = v   // CH LEVEL [n] = [n+1]
    }

    /// Band 0..7 pan, raw 1..127 (64 = center; L63..R63).
    public func vocoderBandPan(_ band: Int) -> UInt8? {
        guard (0..<Self.vocoderBandCount).contains(band) else { return nil }
        return vb.map { data[$0 + 62 + band * 2] }
    }

    public mutating func setVocoderBandPan(_ v: UInt8, _ band: Int) {
        guard let b = vb, (0..<Self.vocoderBandCount).contains(band) else { return }
        data[b + 62 + band * 2] = v
        data[b + 62 + band * 2 + 1] = v   // CH PAN [n] = [n+1]
    }

    // MARK: E.F HOLD LEVELS (+78..+141) — TABLE 4
    //
    // 16 channels x 4 bytes big-endian: HIGH, MID HIGH, MID LOW, LOW, with
    // the LOW byte fixed at 00h (value range 0~7FFFFF00h). Exposed here as a
    // 24-bit level (the low byte is never written).

    public static let vocoderChannelCount = 16

    /// Channel 0..15 envelope-follower hold level, 0..0x7FFFFF.
    public func vocoderEfHoldLevel(_ channel: Int) -> Int? {
        guard (0..<Self.vocoderChannelCount).contains(channel) else { return nil }
        guard let b = vb else { return nil }
        let o = b + 78 + channel * 4
        return (Int(data[o]) << 16) | (Int(data[o + 1]) << 8) | Int(data[o + 2])
    }

    public mutating func setVocoderEfHoldLevel(_ level: Int, _ channel: Int) {
        guard let b = vb, (0..<Self.vocoderChannelCount).contains(channel) else { return }
        let clamped = max(0, min(0x7FFFFF, level))
        let o = b + 78 + channel * 4
        data[o]     = UInt8((clamped >> 16) & 0xFF)
        data[o + 1] = UInt8((clamped >> 8) & 0xFF)
        data[o + 2] = UInt8(clamped & 0xFF)
        data[o + 3] = 0   // LOW byte, always 00h per TABLE 4
    }
}

// MARK: - Enums

/// TABLE 3 +21: filter shift. Raw 0..4 = 0, +1, +2, -1, -2.
public enum VocoderFilterShift: UInt8, CaseIterable, Codable, Hashable {
    case zero = 0
    case up1 = 1
    case up2 = 2
    case down1 = 3
    case down2 = 4

    public var label: String {
        switch self {
        case .zero: return "0"
        case .up1: return "+1"
        case .up2: return "+2"
        case .down1: return "-1"
        case .down2: return "-2"
        }
    }
}

/// TABLE 3 +24, lookup *T-13. The chart's selectable range is 1..7
/// (0 = "---" appears in the lookup; kept for round-trip fidelity).
public enum VocoderFilterModSource: UInt8, CaseIterable, Codable, Hashable {
    case dash = 0
    case aeg = 1
    case lfo1 = 2
    case lfo2 = 3
    case velocity = 4
    case kbdTrack = 5
    case pBend = 6
    case mod = 7

    public var label: String {
        switch self {
        case .dash: return "---"
        case .aeg: return "AEG"
        case .lfo1: return "LFO1"
        case .lfo2: return "LFO2"
        case .velocity: return "VELOCITY"
        case .kbdTrack: return "KBD TRACK"
        case .pBend: return "P.Bend"
        case .mod: return "Mod"
        }
    }
}
