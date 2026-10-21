import Foundation
import PBAPI

/// Patch data model: one program slot with its decoded 254-byte payload.
public struct Patch: Identifiable, Codable {

    public let id: String
    public let bankNumber: Int
    public let patchNumber: Int

    /// The decoded program (TABLE 1/2 layout — see `MicroKORGProgram`).
    public var program: MicroKORGProgram

    /// Full reference flag (is this a full ref patch?)
    public let isFullRef: Bool

    /// Creation timestamp
    public let createdAt: Date

    public init(
        id: String,
        bankNumber: Int,
        patchNumber: Int,
        program: MicroKORGProgram,
        isFullRef: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bankNumber = bankNumber
        self.patchNumber = patchNumber
        self.program = program
        self.isFullRef = isFullRef
        self.createdAt = createdAt
    }

    /// Create from a SysEx message: a `0x40` current-program dump, or a
    /// `0x4C` bank dump (with `bankIndex` selecting one of the 128 programs).
    public static func fromSysEx(
        bank: Int,
        patch: Int,
        sysExData: [UInt8],
        bankIndex: Int = 0
    ) throws -> Patch {
        Patch(
            id: "\(bank)_\(patch)",
            bankNumber: bank,
            patchNumber: patch,
            program: try MicroKORGProgram.fromSysEx(sysExData, bankIndex: bankIndex)
        )
    }

    /// Create a blank reference patch (single program of zeros + defaults).
    public static func createFullRef() -> Patch {
        Patch(
            id: "full_ref",
            bankNumber: 0,
            patchNumber: 0,
            program: .blank(),
            isFullRef: true
        )
    }
}
