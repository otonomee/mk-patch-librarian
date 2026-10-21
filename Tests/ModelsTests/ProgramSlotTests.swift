import XCTest
@testable import Models

/// microKORG S slot addressing: 4 banks (A-D) x 32 programs = 128.
final class ProgramSlotTests: XCTestCase {

    /// Panel labels are letter.group+digit, as the synth's panel prints them.
    /// Flat index math (bank * 32 + patch) is unchanged — only names differ.
    func testLabelMatchesSynthPanel() {
        XCTAssertEqual(ProgramSlot.panelLabel(flat: 0), "A.11")
        XCTAssertEqual(ProgramSlot.panelLabel(flat: 10), "A.23")
        XCTAssertEqual(ProgramSlot.panelLabel(flat: 97), "B.52")

        XCTAssertEqual(ProgramSlot.label(bank: 0, patch: 0), "A.11")
        XCTAssertEqual(ProgramSlot.label(bank: 0, patch: 9), "A.22")
        XCTAssertEqual(ProgramSlot.label(bank: 3, patch: 1), "B.52")
        XCTAssertEqual(ProgramSlot.label(bank: 3, patch: 31), "B.88")
        XCTAssertEqual(ProgramSlot.bankLetter(0), "A")
        XCTAssertEqual(ProgramSlot.bankLetter(3), "D")
    }

    /// Every flat index has a distinct label, and the panel's group/digit
    /// split matches the dial (8 slots per dial position).
    func testPanelLabelsAreUniqueAcrossAll128Slots() {
        var seen = Set<String>()
        for flat in 0..<128 {
            let label = ProgramSlot.panelLabel(flat: flat)
            XCTAssertTrue((0..<128).contains(flat))
            XCTAssertTrue(seen.insert(label).inserted, "duplicate label \(label)")
            // side A covers 0-63, side B covers 64-127.
            XCTAssertEqual(label.first, flat < 64 ? "A" : "B")
            let group = flat % 64 / 8 + 1
            let digit = flat % 8 + 1
            XCTAssertEqual(label, "\(flat < 64 ? "A" : "B").\(group)\(digit)")
        }
        XCTAssertEqual(seen.count, 128)
    }

    /// The mapping table from the handoff: old A01-D32 names -> panel names.
    func testOldToPanelLabelTable() {
        XCTAssertEqual(ProgramSlot.label(bank: 0, patch: 7), "A.18")    // A01-A08
        XCTAssertEqual(ProgramSlot.label(bank: 0, patch: 8), "A.21")    // A09-A16
        XCTAssertEqual(ProgramSlot.label(bank: 0, patch: 31), "A.48")   // A25-A32
        XCTAssertEqual(ProgramSlot.label(bank: 1, patch: 7), "A.58")    // B01-B08
        XCTAssertEqual(ProgramSlot.label(bank: 1, patch: 31), "A.88")   // B25-B32
        XCTAssertEqual(ProgramSlot.label(bank: 2, patch: 7), "B.18")    // C01-C08
    }

    // MARK: C/D extra banks (HANDOFF-v10 §2a)

    func testExtraBankLabelsMatchPanel() {
        XCTAssertEqual(ProgramSlot.extraLabel(bank: 4, patch: 0), "C.11")
        XCTAssertEqual(ProgramSlot.extraLabel(bank: 4, patch: 63), "C.88")
        XCTAssertEqual(ProgramSlot.extraLabel(bank: 5, patch: 0), "D.11")
        XCTAssertEqual(ProgramSlot.extraLabel(bank: 5, patch: 63), "D.88")
    }

    func testAnyLabelHandlesAAndExtraBanks() {
        XCTAssertEqual(ProgramSlot.anyLabel(bank: 0, patch: 0), "A.11")
        XCTAssertEqual(ProgramSlot.anyLabel(bank: 3, patch: 31), "B.88")
        XCTAssertEqual(ProgramSlot.anyLabel(bank: 4, patch: 0), "C.11")
        XCTAssertEqual(ProgramSlot.anyLabel(bank: 5, patch: 63), "D.88")
    }

    func testExtraBankSelectMidiMapping() {
        // C = bank LSB 1, program changes 0...63
        XCTAssertEqual(ProgramSlot.bankSelectLSB(bank: 4), 1)
        XCTAssertEqual(ProgramSlot.programChange(bank: 4, patch: 0), 0)
        XCTAssertEqual(ProgramSlot.programChange(bank: 4, patch: 63), 63)

        // D = bank LSB 1, program changes 64...127
        XCTAssertEqual(ProgramSlot.bankSelectLSB(bank: 5), 1)
        XCTAssertEqual(ProgramSlot.programChange(bank: 5, patch: 0), 64)
        XCTAssertEqual(ProgramSlot.programChange(bank: 5, patch: 63), 127)

        // A/B stay on LSB 0 and are not "extra".
        XCTAssertFalse(ProgramSlot.isExtraBank(0))
        XCTAssertFalse(ProgramSlot.isExtraBank(3))
        XCTAssertTrue(ProgramSlot.isExtraBank(4))
        XCTAssertTrue(ProgramSlot.isExtraBank(5))
    }

    func testExtraBankBoundsClamp() {
        XCTAssertEqual(ProgramSlot.extraLabel(bank: 4, patch: 1000), "C.88")
        XCTAssertEqual(ProgramSlot.extraLabel(bank: 4, patch: -1), "C.11")
        XCTAssertEqual(ProgramSlot.programChange(bank: 4, patch: 1000), 63)
        XCTAssertEqual(ProgramSlot.programChange(bank: 5, patch: -1), 64)
    }

    func testFlatIndexMatchesBankDumpOrder() {
        // The dump is 128 programs at a 254-byte stride; A01 is index 0 and
        // D32 is index 127, so index = bank * 32 + patch.
        XCTAssertEqual(ProgramSlot.index(bank: 0, patch: 0), 0)
        XCTAssertEqual(ProgramSlot.index(bank: 1, patch: 0), 32)
        XCTAssertEqual(ProgramSlot.index(bank: 3, patch: 31), 127)

        // Every (bank, patch) maps to a unique index covering 0...127 exactly.
        var seen = Set<Int>()
        for bank in 0..<ProgramSlot.bankCount {
            for patch in 0..<ProgramSlot.patchesPerBank {
                let index = ProgramSlot.index(bank: bank, patch: patch)
                XCTAssertTrue((0..<128).contains(index), "index \(index) out of range")
                XCTAssertTrue(seen.insert(index).inserted, "duplicate index \(index)")
            }
        }
        XCTAssertEqual(seen.count, 128)
    }

    func testBrowserStateIsFourByThirtyTwo() {
        let state = BankBrowserState()
        XCTAssertEqual(state.banks, [0, 1, 2, 3])
        XCTAssertEqual(state.patches.count, 32)
        XCTAssertEqual(state.patches.first, 0)
        XCTAssertEqual(state.patches.last, 31)
    }

    // MARK: Letter+slot addressing (destination picker: 4 letters x 64 slots
    // each, matching how the synth's own panel is actually addressed — the
    // internal `bank` 0-3 split for A/B into two 32-slot halves is an
    // implementation detail the picker shouldn't have to know about).

    func testResolveLetterSlotMatchesPanelLabelForAllFourLetters() {
        // A: letter 0, slots 0...63 -> A.11...A.88
        XCTAssertEqual(ProgramSlot.anyLabel(bank: ProgramSlot.resolve(letter: 0, slot: 0).bank,
                                             patch: ProgramSlot.resolve(letter: 0, slot: 0).patch), "A.11")
        XCTAssertEqual(ProgramSlot.anyLabel(bank: ProgramSlot.resolve(letter: 0, slot: 63).bank,
                                             patch: ProgramSlot.resolve(letter: 0, slot: 63).patch), "A.88")
        // B: letter 1
        XCTAssertEqual(ProgramSlot.anyLabel(bank: ProgramSlot.resolve(letter: 1, slot: 0).bank,
                                             patch: ProgramSlot.resolve(letter: 1, slot: 0).patch), "B.11")
        XCTAssertEqual(ProgramSlot.anyLabel(bank: ProgramSlot.resolve(letter: 1, slot: 63).bank,
                                             patch: ProgramSlot.resolve(letter: 1, slot: 63).patch), "B.88")
        // C: letter 2 (extra bank 4)
        XCTAssertEqual(ProgramSlot.anyLabel(bank: ProgramSlot.resolve(letter: 2, slot: 0).bank,
                                             patch: ProgramSlot.resolve(letter: 2, slot: 0).patch), "C.11")
        XCTAssertEqual(ProgramSlot.anyLabel(bank: ProgramSlot.resolve(letter: 2, slot: 63).bank,
                                             patch: ProgramSlot.resolve(letter: 2, slot: 63).patch), "C.88")
        // D: letter 3 (extra bank 5)
        XCTAssertEqual(ProgramSlot.anyLabel(bank: ProgramSlot.resolve(letter: 3, slot: 0).bank,
                                             patch: ProgramSlot.resolve(letter: 3, slot: 0).patch), "D.11")
        XCTAssertEqual(ProgramSlot.anyLabel(bank: ProgramSlot.resolve(letter: 3, slot: 63).bank,
                                             patch: ProgramSlot.resolve(letter: 3, slot: 63).patch), "D.88")
    }

    func testLetterAndSlotIsTheInverseOfResolveAcrossAll256Slots() {
        for letter in 0..<4 {
            for slot in 0..<64 {
                let resolved = ProgramSlot.resolve(letter: letter, slot: slot)
                let back = ProgramSlot.letterAndSlot(bank: resolved.bank, patch: resolved.patch)
                XCTAssertEqual(back.letter, letter, "letter round-trip failed for \(letter)/\(slot)")
                XCTAssertEqual(back.slot, slot, "slot round-trip failed for \(letter)/\(slot)")
            }
        }
    }

    func testLetterSlotLabelMatchesPanelGroupDigit() {
        XCTAssertEqual(ProgramSlot.letterSlotLabel(0), "11")
        XCTAssertEqual(ProgramSlot.letterSlotLabel(7), "18")
        XCTAssertEqual(ProgramSlot.letterSlotLabel(8), "21")
        XCTAssertEqual(ProgramSlot.letterSlotLabel(63), "88")
    }

    func testResolveCoversAllFourLettersWithDistinctFlatSlots() {
        // 256 (letter, slot) pairs must all resolve to distinct (bank, patch).
        var seen = Set<String>()
        for letter in 0..<4 {
            for slot in 0..<64 {
                let r = ProgramSlot.resolve(letter: letter, slot: slot)
                XCTAssertTrue(seen.insert("\(r.bank)/\(r.patch)").inserted,
                               "duplicate destination for letter \(letter) slot \(slot)")
            }
        }
        XCTAssertEqual(seen.count, 256)
    }
}
