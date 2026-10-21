import XCTest
import PBAPI
@testable import Models

/// Import microKORG program files (.prg single dumps, .set bank dumps).
///
/// Fixtures are synthesized in-process via `KorgSysEx.message(_:data:)` rather
/// than read from disk, so the suite needs no bundled patch data (commercial
/// or otherwise) and runs identically on any machine.
final class ProgramFileImportTests: XCTestCase {

    private func syntheticProgram(named name: String) -> MicroKORGProgram {
        var program = MicroKORGProgram.blank()
        program.setName(name)
        return program
    }

    func testImportSinglePrgFile() throws {
        let program = syntheticProgram(named: "TEST PATCH")
        let frame = KorgSysEx.message(.currentProgramDump, data: program.data)

        let imported = try ProgramFileImport.programs(from: frame)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.name, "TEST PATCH")
        XCTAssertEqual(imported.first?.program.data.count, 254)
    }

    func testImportSetFileContains128Programs() throws {
        var bank: [UInt8] = []
        for index in 0..<KorgSysEx.programsPerBank {
            bank.append(contentsOf: syntheticProgram(named: "Synth \(index)").data)
        }
        let allData = bank + GlobalSettings.blank().data
        let frame = KorgSysEx.message(.allDataDump, data: allData)

        let imported = try ProgramFileImport.programs(from: frame)
        XCTAssertEqual(imported.count, 128)
        XCTAssertEqual(imported.first?.name, "Synth 0")
        XCTAssertEqual(imported.last?.name, "Synth 127")
    }

    /// A file can contain several standalone dumps back to back (e.g. a few
    /// `.prg` exports concatenated); each becomes its own unpositioned import.
    func testImportMultipleConcatenatedProgramDumps() throws {
        let first = KorgSysEx.message(.currentProgramDump, data: syntheticProgram(named: "FIRST").data)
        let second = KorgSysEx.message(.currentProgramDump, data: syntheticProgram(named: "SECOND").data)

        let imported = try ProgramFileImport.programs(from: first + second)
        XCTAssertEqual(imported.count, 2)
        XCTAssertEqual(imported.map(\.name), ["FIRST", "SECOND"])
        XCTAssertTrue(imported.allSatisfy { !$0.hasKnownSourcePosition })
    }

    func testImportEmptyDataThrows() {
        XCTAssertThrowsError(try ProgramFileImport.programs(from: [])) { error in
            XCTAssertEqual((error as? ProgramImportError)?.localizedDescription,
                           ProgramImportError.noSysExFramesFound.localizedDescription)
        }
    }

    func testExtractSysExFramesFromJunkPadding() {
        let junk: [UInt8] = [0x00, 0xF0, 0x42, 0x30, 0x58, 0x40, 0xF7, 0x00]
        let frames = ProgramFileImport.extractSysExFrames(from: junk)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first, [0xF0, 0x42, 0x30, 0x58, 0x40, 0xF7])
    }
}
