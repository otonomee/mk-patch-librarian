import Foundation
import PBAPI

// MARK: - MicroKORG global settings (200-byte decoded dump)
//
// Layout is identical in both charts (rev 1.4 TABLE 6 = microKORG S rev 1.01
// TABLE 5; byte offsets unchanged, verified by the HANDOFF-v12.md §2.1
// diff). On the S chart bytes 72..199 are `(Reserved)` except byte 72 B0
// (Speaker Off/On) and 80..87 (Favorite program slots) — new params the
// original chart lacks; this model reads the legacy dump and preserves
// them untouched. Verified against the reference `microkorg-global.syx`:
//
//   byte 10/11      = 90/95 (CC numbers, chart range -1..95 where -1 = OFF)
//   bytes 18..59    = factory knob/switch CC map, contains 0xFF (= -1 = OFF)
//   bytes 72..199   = program-change map, identity 0..127 in the dump
//   byte 0 (Master Tune), byte 1 (Transpose), bytes 60..71 (user scale)
//                     are two's-complement int8 ("0+/-N" encoding)
public struct GlobalSettings: Codable, Equatable {

    /// The decoded global data, always `KorgSysEx.globalDataSize` (200) bytes.
    public private(set) var data: [UInt8]

    // MARK: Layout (TABLE 6)

    public enum Offset {
        public static let masterTune = 0        // int8, 0 = A440, +/-100 cents
        public static let transpose = 1         // int8, -12..+12
        public static let velocity = 3          // 1..127
        public static let velocityCurve = 4     // 0..7 = curve 1..8, 8 = const
        public static let switches = 5          // bit2 = local, bit0 = memory protect
        public static let clock = 8             // bits0-1: 0=Int 1=Ext 2=Auto
        public static let midiChannel = 9       // bits0-3: 0..15 = ch 1..16
        public static let syncCtrlCC = 10       // int8, -1 = OFF, else CC 0..95
        public static let timbreSelectCtrlCC = 11
        public static let midi1Ctrl = 14        // 0 = P.Bend
        public static let midi2Ctrl = 15        // 3 = CC#01
        public static let filters = 16          // bit7 = SysEx filter, bits0-1 = note recv
        public static let channelFilters = 17   // bit6 = P.Bend, bit2 = CtrlChg, bit0 = ProgChg
        public static let knobCCMap = 18        // 42 bytes (int8, -1 = OFF)
        public static let userScale = 60        // 12 bytes int8, cents
        public static let programChangeMap = 72 // 128 bytes, internal program no.
    }

    public static let knobCCMapCount = 42
    public static let userScaleCount = 12
    public static let programChangeMapCount = 128

    // MARK: Init

    public init?(data: [UInt8]) {
        guard data.count == KorgSysEx.globalDataSize else { return nil }
        self.data = data
    }

    /// Reasonable defaults matching the reference dump where it is a sane
    /// default (SysEx enabled, local on, identity program map).
    public static func blank() -> GlobalSettings {
        var settings = GlobalSettings(data: [UInt8](repeating: 0, count: KorgSysEx.globalDataSize))!
        settings.data[Offset.velocity] = 64
        settings.data[Offset.velocityCurve] = 2
        settings.data[Offset.switches] = 0b0000_0100 // local on, protect off
        settings.data[Offset.midi2Ctrl] = 3           // CC#01
        settings.data[Offset.filters] = 0x80          // SysEx filter enabled
        settings.data[Offset.channelFilters] = 0b0100_0101 // all filters enabled
        for index in 0..<knobCCMapCount {
            settings.data[Offset.knobCCMap + index] = 0xFF // OFF
        }
        for index in 0..<programChangeMapCount {
            settings.data[Offset.programChangeMap + index] = UInt8(index)
        }
        return settings
    }

    /// Decode a complete `0x51` SysEx message.
    public static func fromSysEx(_ message: [UInt8]) throws -> GlobalSettings {
        let parsed = try KorgSysEx.parse(message)
        guard parsed.command == .globalDump else {
            throw KorgSysExError.unexpectedReply(
                expected: KorgSysEx.Command.globalDump.rawValue,
                got: parsed.command.rawValue)
        }
        guard let settings = GlobalSettings(data: parsed.data) else {
            throw KorgSysExError.wrongDataSize(
                expected: KorgSysEx.globalDataSize, got: parsed.data.count)
        }
        return settings
    }

    /// Encode as a complete `0x51` message for writing back to the synth.
    public func toSysEx() -> [UInt8] {
        KorgSysEx.message(.globalDump, data: data)
    }

    // MARK: Display helpers

    /// Chart: 0+/-100 = 430~440~450 Hz, i.e. 0.1 Hz per step.
    public static func masterTuneHz(cents: Int) -> Double {
        440.0 + Double(cents) / 10.0
    }

    /// Curves 1...8 plus Const.
    public static let velocityCurveCount = 9
    public static let velocityCurveConst: UInt8 = 8

    public static func velocityCurveLabel(_ value: UInt8) -> String {
        value >= velocityCurveConst ? "Const" : "\(Int(value) + 1)"
    }

    // MARK: Accessors

    private func int8(_ offset: Int) -> Int { Int(Int8(bitPattern: data[offset])) }

    private mutating func setInt8(_ offset: Int, _ value: Int) {
        data[offset] = UInt8(bitPattern: Int8(max(-128, min(127, value))))
    }

    /// Master tune in cents around A440 (-100..+100; -100 = 430 Hz).
    public var masterTune: Int { int8(Offset.masterTune) }
    public mutating func setMasterTune(_ v: Int) { setInt8(Offset.masterTune, v) }

    /// Global transpose, -12..+12 semitones.
    public var transpose: Int { int8(Offset.transpose) }
    public mutating func setTranspose(_ v: Int) { setInt8(Offset.transpose, v) }

    /// Velocity value, 1..127 (see chart *T-7).
    public var velocityValue: UInt8 { data[Offset.velocity] }
    public mutating func setVelocityValue(_ v: UInt8) { data[Offset.velocity] = v }

    /// 0..7 = curve 1..8, 8 = constant.
    public var velocityCurve: UInt8 { data[Offset.velocityCurve] }
    public mutating func setVelocityCurve(_ v: UInt8) { data[Offset.velocityCurve] = v }

    public var localControl: Bool { data[Offset.switches] & 0b0100 != 0 }
    public mutating func setLocalControl(_ on: Bool) {
        data[Offset.switches] = on ? data[Offset.switches] | 0b0100
                                   : data[Offset.switches] & ~0b0100
    }

    public var memoryProtect: Bool { data[Offset.switches] & 0b0001 != 0 }
    public mutating func setMemoryProtect(_ on: Bool) {
        data[Offset.switches] = on ? data[Offset.switches] | 0b0001
                                   : data[Offset.switches] & ~0b0001
    }

    /// 0 = Internal, 1 = External, 2 = Auto.
    public var clock: UInt8 { data[Offset.clock] & 0b11 }
    public mutating func setClock(_ v: UInt8) { data[Offset.clock] = v & 0b11 }

    /// 0..15 = MIDI channel 1..16.
    public var midiChannel: UInt8 { data[Offset.midiChannel] & 0x0F }
    public mutating func setMidiChannel(_ v: UInt8) { data[Offset.midiChannel] = v & 0x0F }

    /// Sync control CC number, -1 = OFF.
    public var syncCtrlCC: Int { int8(Offset.syncCtrlCC) }
    public mutating func setSyncCtrlCC(_ v: Int) { setInt8(Offset.syncCtrlCC, v) }

    /// Timbre select control CC number, -1 = OFF.
    public var timbreSelectCtrlCC: Int { int8(Offset.timbreSelectCtrlCC) }
    public mutating func setTimbreSelectCtrlCC(_ v: Int) { setInt8(Offset.timbreSelectCtrlCC, v) }

    /// MIDI1 controller, 0 = Pitch Bend (chart fixed value).
    public var midi1Ctrl: UInt8 { data[Offset.midi1Ctrl] }
    public var midi2Ctrl: UInt8 { data[Offset.midi2Ctrl] }

    /// SysEx filter: true = enabled (messages received/transmitted).
    public var sysExFilterEnabled: Bool { data[Offset.filters] & 0x80 != 0 }
    public mutating func setSysExFilterEnabled(_ on: Bool) {
        data[Offset.filters] = on ? data[Offset.filters] | 0x80
                                  : data[Offset.filters] & ~0x80
    }

    public var pitchBendFilterEnabled: Bool { data[Offset.channelFilters] & 0x40 != 0 }
    public var controlChangeFilterEnabled: Bool { data[Offset.channelFilters] & 0x04 != 0 }
    public var programChangeFilterEnabled: Bool { data[Offset.channelFilters] & 0x01 != 0 }

    /// Knob & switch CC map, 42 entries; -1 = OFF (chart *T-9 order).
    public var knobCCMap: [Int] {
        (0..<Self.knobCCMapCount).map { int8(Offset.knobCCMap + $0) }
    }

    public mutating func setKnobCC(_ cc: Int, at index: Int) {
        guard (0..<Self.knobCCMapCount).contains(index) else { return }
        setInt8(Offset.knobCCMap + index, cc)
    }

    /// User scale cents, 12 entries (C..B), -100..+100.
    public var userScale: [Int] {
        (0..<Self.userScaleCount).map { int8(Offset.userScale + $0) }
    }

    /// MIDI-in program change map: internal program for each of the 128
    /// incoming program change numbers (identity by default).
    public var programChangeMap: [UInt8] {
        Array(data[Offset.programChangeMap..<(Offset.programChangeMap + Self.programChangeMapCount)])
    }

    public mutating func setProgramChangeMapEntry(_ program: UInt8, at index: Int) {
        guard (0..<Self.programChangeMapCount).contains(index) else { return }
        data[Offset.programChangeMap + index] = program
    }
}
