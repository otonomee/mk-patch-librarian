import XCTest
@testable import UIViews

/// v15 §3.5 acceptance — hover help exists for every control backed by the
/// byte-coverage registry. The dictionary keys must be EXACTLY the registry's
/// non-reserved entry names (both directions): a new param without help fails
/// here, and a stale sentence for a removed param fails too.
final class EditorHelpTests: XCTestCase {

    func testHelpCoversExactlyTheNonReservedRegistryEntries() {
        let covered = Set(EditorByteCoverage.entries.filter { !$0.reservedOnS }.map(\.name))
        let helped = Set(EditorHelp.byParam.keys)

        let missing = covered.subtracting(helped).sorted()
        XCTAssertTrue(missing.isEmpty,
                      "Registry entries without hover help: \(missing)")

        let stale = helped.subtracting(covered).sorted()
        XCTAssertTrue(stale.isEmpty,
                      "Help text for params no longer in the registry: \(stale)")
    }

    func testEveryHelpSentenceIsNonEmptyAndOneLine() {
        for (name, text) in EditorHelp.byParam {
            XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(name) has empty help")
            XCTAssertFalse(text.contains("\n"), "\(name) help must be one line")
        }
    }

    func testHelpTextResolutionPrefersInlineOverRegistry() {
        XCTAssertEqual(
            EditorHelp.text(param: "filterCutoff", inline: nil),
            EditorHelp.byParam["filterCutoff"])
        XCTAssertEqual(EditorHelp.text(param: nil, inline: "inline"), "inline")
        XCTAssertEqual(EditorHelp.text(param: "nope", inline: nil), "")
    }
}
