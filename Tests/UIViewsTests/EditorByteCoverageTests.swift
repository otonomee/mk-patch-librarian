import XCTest
import Models
@testable import UIViews

/// §3e acceptance test — the definition of "a literal copy of all the params".
///
/// Walks every byte of TABLE 1 (0...37) and TABLE 2 in both timbre halves
/// (+0...+51 at base 38 → 38...89, and at base 146 → 146...197) and fails if
/// any non-dummy byte has no editor binding in `EditorByteCoverage`, if the
/// registry maps a dummy byte, or if a registered path is not writable. Byte
/// 16 (voice mode) is display-only by design (changing it restructures the
/// whole editor). TABLE 2 entries carry `scope: .timbre` and cover both
/// halves; entries may never map the dummy ranges 90...145 / 198...253.
final class EditorByteCoverageTests: XCTestCase {

    /// Dummy bytes per the chart — never exposed.
    private let table1Dummies: Set<Int> = [12, 13, 18]
    /// +11 is dummy in each half; +52..107 lie past each walk range.
    private let table2Dummies: Set<Int> = [38 + 11, 146 + 11]
    /// The dummy/reserved byte ranges between and after the live halves.
    private let dummyRanges: [ClosedRange<Int>] = [90...145, 198...253]

    private var expectedBytes: Set<Int> {
        let table1 = Set(0...37).subtracting(table1Dummies)
        let timbre1 = Set(38...89).subtracting(table2Dummies)
        let timbre2 = Set(146...197).subtracting(table2Dummies)
        return table1.union(timbre1).union(timbre2)
    }

    /// Byte offsets an entry accounts for: `.timbre` entries list Timbre 1
    /// addresses and cover the same chart offsets at base 146 as well.
    private func coveredBytes(of entry: EditorByteCoverage.Entry) -> [Int] {
        guard entry.scope == .timbre else { return entry.bytes }
        return entry.bytes + entry.bytes.map { $0 + 108 } // 146 - 38
    }

    func testEveryNonDummyChartByteHasABinding() {
        var covered = Set<Int>()
        for entry in EditorByteCoverage.entries {
            for byte in coveredBytes(of: entry) {
                XCTAssertTrue(
                    expectedBytes.contains(byte),
                    "\(entry.name) maps to byte \(byte), which is a dummy or out of range")
                covered.insert(byte)
            }
            if entry.writable {
                XCTAssertTrue(
                    Self.writableChecks.contains { $0(entry.path) },
                    "\(entry.name) is registered writable but no WritableKeyPath matches")
            }
        }

        let missing = expectedBytes.subtracting(covered).sorted()
        XCTAssertTrue(missing.isEmpty, "No editor binding for byte(s): \(missing)")
    }

    /// No entry — program- or timbre-scoped — may touch the dummy ranges
    /// between/after the two live halves.
    func testNoEntryMapsDummyRanges() {
        for entry in EditorByteCoverage.entries {
            let bad = coveredBytes(of: entry).filter { byte in
                dummyRanges.contains { $0.contains(byte) }
            }
            XCTAssertTrue(bad.isEmpty,
                          "\(entry.name) maps into a dummy range: \(bad.sorted())")
        }
    }

    /// One check per concrete value type used in the registry; a writable
    /// entry must downcast to `WritableKeyPath` for exactly one of them.
    private static let writableChecks: [(PartialKeyPath<EditorState>) -> Bool] = [
        { $0 is WritableKeyPath<EditorState, UInt8> },
        { $0 is WritableKeyPath<EditorState, Int> },
        { $0 is WritableKeyPath<EditorState, Bool> },
        { $0 is WritableKeyPath<EditorState, String> },
        { $0 is WritableKeyPath<EditorState, VoiceMode> },
        { $0 is WritableKeyPath<EditorState, Osc1Wave> },
        { $0 is WritableKeyPath<EditorState, Osc2Wave> },
        { $0 is WritableKeyPath<EditorState, Osc2Mod> },
        { $0 is WritableKeyPath<EditorState, FilterType> },
        { $0 is WritableKeyPath<EditorState, ModFxType> },
        { $0 is WritableKeyPath<EditorState, DelayType> },
        { $0 is WritableKeyPath<EditorState, ArpType> },
        { $0 is WritableKeyPath<EditorState, LFO1Wave> },
        { $0 is WritableKeyPath<EditorState, LFO2Wave> },
        { $0 is WritableKeyPath<EditorState, PatchSource> },
        { $0 is WritableKeyPath<EditorState, PatchDestination> },
    ]

    func testRegistryNeverExposesDummyBytes() {
        let exposed = EditorByteCoverage.entries
            .flatMap(\.bytes)
            .filter { table1Dummies.contains($0) || table2Dummies.contains($0) }
        XCTAssertTrue(exposed.isEmpty, "Registry exposes dummy byte(s): \(exposed.sorted())")
    }

    /// Every registered binding is writable since the voice-mode picker
    /// shipped (v13 §4.1) — the last display-only param is gone. Kept as a
    /// pin: a future read-only entry must deliberately re-add a rule here.
    func testNoEntryIsDisplayOnly() {
        let displayOnly = EditorByteCoverage.entries.filter { !$0.writable }.map(\.name)
        XCTAssertTrue(displayOnly.isEmpty, "Display-only entries: \(displayOnly)")
    }

    /// The S chart (rev 1.01) marks these bytes `(Reserved)` — the editor
    /// keeps their accessors (bytes round-trip untouched) but shows no
    /// control. Pins the exact set so accidental hide/show drift fails here.
    func testReservedOnSSetIsExactlyTheChartRows() {
        let reserved = Set(
            EditorByteCoverage.entries.filter(\.reservedOnS).map(\.name))
        XCTAssertEqual(reserved, [
            "midiChannel",     // TABLE 2 +0
            "keyPriority",     // TABLE 2 +1 B0-2
            "scaleKey",        // TABLE 1 byte 17
            "scaleType",       // TABLE 1 byte 17
            "filterVelocitySense", // TABLE 2 +23
            "ampVelocitySense",    // TABLE 2 +28
        ])
        // Reserved entries stay writable accessors — only the UI hides them.
        for entry in EditorByteCoverage.entries where entry.reservedOnS {
            XCTAssertTrue(entry.writable, "\(entry.name) must keep its accessor")
        }
    }
}
