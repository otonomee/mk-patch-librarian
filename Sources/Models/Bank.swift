import Foundation
import Combine

/// Bank data model - manages collections of patches
public struct Bank: Identifiable, Codable {

    public let id: String
    public let name: String?
    public let bankNumber: Int

    /// Patches in this bank (0-15 for MicroKORG)
    public var patches: [Patch]

    /// Number of patches currently in this bank.
    public var patchCount: Int { patches.count }

    public init(
        id: String,
        name: String?,
        bankNumber: Int,
        patches: [Patch] = []
    ) {
        self.id = id
        self.name = name
        self.bankNumber = bankNumber
        self.patches = patches
    }

    /// Create a new empty bank
    public static func createEmpty(
        id: String,
        name: String? = nil,
        bankNumber: Int
    ) -> Bank {
        return Bank(
            id: id,
            name: name,
            bankNumber: bankNumber,
            patches: []
        )
    }

    /// Get patch at index (0-15)
    public func patch(at index: Int) -> Patch? {
        guard 0 <= index && index < patches.count else { return nil }
        return patches[index]
    }

    /// Set patch at index
    public mutating func setPatch(
        at index: Int,
        with patch: Patch
    ) {
        guard 0 <= index && index < patches.count else { return }
        patches[index] = patch
    }
}

/// Bank browser model for UI
public struct BankBrowserModel: Identifiable {

    public let id: String
    public let bankNumber: Int
    public let patchNumber: Int

    /// Display name (e.g., "Bank 0 / Patch 1")
    public var displayName: String {
        return "Bank \(bankNumber) / Patch \(patchNumber)"
    }

    public init(bankNumber: Int, patchNumber: Int) {
        self.id = "\(bankNumber)_\(patchNumber)"
        self.bankNumber = bankNumber
        self.patchNumber = patchNumber
    }
}

/// Bank browser state (for UI controller).
/// A reference type so SwiftUI can observe changes via @StateObject.
public final class BankBrowserState: ObservableObject {

    /// The last cell the user opened in the editor (nil = none — nothing is
    /// highlighted at launch, since "selected" only means "was opened").
    @Published public var selectedBank: Int?
    @Published public var selectedPatch: Int?

    /// microKORG S layout: 4 banks (A-D) x 32 programs = 128.
    public let banks: [Int] = Array(0..<ProgramSlot.bankCount)
    public let patches: [Int] = Array(0..<ProgramSlot.patchesPerBank)

    @Published public var isLoading: Bool = false
    @Published public var error: Error?

    public init() {
        // Initialize with default bank/patch selection
    }
}

/// Program slot addressing for the microKORG S: 4 banks (A-D) x 32 programs.
///
/// The flat program index inside a 32512-byte dump is `bank * 32 + patch`,
/// matching `KorgSysEx.program(_:inBank:)`.
public enum ProgramSlot {

    public static let bankCount = 4
    public static let patchesPerBank = 32

    /// Flat index into the decoded bank (0...127).
    public static func index(bank: Int, patch: Int) -> Int {
        bank * patchesPerBank + patch
    }

    /// Slot label as the synth's panel prints it: (0,0) -> "A.11",
    /// flat 10 -> "A.23", flat 97 -> "B.52".
    ///
    /// The panel picks the letter from the side (64 programs each), the
    /// group (1-8) from a program-select dial, and the digit (1-8) within
    /// the group. The flat index math is unchanged: `bank * 32 + patch`.
    public static func label(bank: Int, patch: Int) -> String {
        panelLabel(flat: index(bank: bank, patch: patch))
    }

    /// Flat index (0...127) -> panel label, e.g. 0 -> "A.11", 97 -> "B.52".
    ///
    /// side = flat / 64; group = (flat % 64) / 8 + 1; digit = flat % 8 + 1.
    public static func panelLabel(flat: Int) -> String {
        let clamped = max(0, min(bankCount * patchesPerBank - 1, flat))
        let side = clamped / 64
        let group = clamped % 64 / 8 + 1
        let digit = clamped % 8 + 1
        return "\(bankLetter(side)).\(group)\(digit)"
    }

    /// "A"..."D" for a bank column header.
    public static func bankLetter(_ bank: Int) -> String {
        String(Character(UnicodeScalar(65 + max(0, min(bankCount - 1, bank)))!))
    }

    // MARK: C/D banks (browse-only)
    //
    // The 0x0F ALL DATA dump carries ONLY A+B (128 programs). C and D live
    // beyond it and are reachable one program at a time via bank select
    // (CC32=1, then PC 0...63 for C / 64...127 for D) followed by an edit
    // buffer read — HANDOFF-v10 §2a, verified live:
    //
    //   C = 64 factory presets (C.11 "SynthHarp" ... C.88 "VocoderDWGS")
    //   D = 64 empty user slots (every slot byte-identical: 12 spaces, saw,
    //       cutoff 127, amp 127); Austin: "D's are all empty factory, for
    //       user to save to."
    //
    // C/D carry no flat index into a loaded bank and the 0x11 write path only
    // addresses 0...127 (A/B), so a C/D cell is BROWSE-ONLY: it opens the
    // editor for listening, and the Save button is disabled there.

    /// Slots per C/D bank (half of A/B's 128).
    public static let extraPatchesPerBank = 64

    /// True for a C/D browse cell (bank 4 = C, bank 5 = D).
    public static func isExtraBank(_ bank: Int) -> Bool {
        bank >= bankCount
    }

    /// Program Change that selects an extra-bank slot on the synth.
    ///
    /// C = PC 0...63, D = PC 64...127 (both under bank LSB 1).
    public static func programChange(bank: Int, patch: Int) -> Int {
        let slot = max(0, min(extraPatchesPerBank - 1, patch))
        return bank == bankCount ? slot : extraPatchesPerBank + slot
    }

    /// Bank-select LSB (CC32) for a bank: 0 for A/B, 1 for C/D.
    public static func bankSelectLSB(bank: Int) -> Int {
        isExtraBank(bank) ? 1 : 0
    }

    /// Panel label for a C/D cell: (4,0) -> "C.11", (5,63) -> "D.88".
    ///
    /// Same 8-groups-of-8 panel geometry as A/B, so the letter block reads
    /// like the synth's own panel. Absolute banks 4 and 5 map to letters C and D.
    public static func extraLabel(bank: Int, patch: Int) -> String {
        let letterIndex = max(0, min(3, bank - 2)) // 4 -> C, 5 -> D
        let letter = bankLetter(letterIndex)
        let slot = max(0, min(extraPatchesPerBank - 1, patch))
        let group = slot / 8 + 1
        let digit = slot % 8 + 1
        return "\(letter).\(group)\(digit)"
    }

    /// Label for any cell, A/B or C/D.
    public static func anyLabel(bank: Int, patch: Int) -> String {
        isExtraBank(bank) ? extraLabel(bank: bank, patch: patch)
                          : label(bank: bank, patch: patch)
    }

    // MARK: Letter+slot addressing (for the import destination picker)
    //
    // Every slot the synth has is one of 4 letters (A/B/C/D) x 64 slots
    // each — that's how the panel addresses them and how a picker should
    // too. It's NOT how `bank`/`patch` work internally: A/B split into two
    // 32-slot `bank` halves (0/1 for A, 2/3 for B) to match the flat 0-127
    // dump index, while C/D each get one `bank` value (4, 5) with patch
    // 0-63 directly. These two functions are the only place that split
    // needs to be known outside this file.

    public static let letterCount = 4
    public static let slotsPerLetter = 64

    /// Letter index (0=A, 1=B, 2=C, 3=D) + slot (0-63) -> the `bank`/`patch`
    /// pair every other API in this file (and `MainWindowController`) uses.
    public static func resolve(letter: Int, slot: Int) -> (bank: Int, patch: Int) {
        let letter = max(0, min(letterCount - 1, letter))
        let slot = max(0, min(slotsPerLetter - 1, slot))
        if letter < 2 {
            // A (letter 0) = flat 0-63, B (letter 1) = flat 64-127.
            let flat = letter * 64 + slot
            return (flat / patchesPerBank, flat % patchesPerBank)
        }
        // C (letter 2) = bank 4, D (letter 3) = bank 5; patch is the slot.
        return (bankCount + (letter - 2), slot)
    }

    /// Inverse of `resolve`.
    public static func letterAndSlot(bank: Int, patch: Int) -> (letter: Int, slot: Int) {
        if isExtraBank(bank) {
            return (2 + min(1, bank - bankCount), max(0, min(slotsPerLetter - 1, patch)))
        }
        let flat = index(bank: bank, patch: patch)
        return (flat / 64, flat % 64)
    }

    /// Two-digit panel code for a slot within a letter: 0 -> "11", 63 -> "88".
    public static func letterSlotLabel(_ slot: Int) -> String {
        let clamped = max(0, min(slotsPerLetter - 1, slot))
        return "\(clamped / 8 + 1)\(clamped % 8 + 1)"
    }
}
