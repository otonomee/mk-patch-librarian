import SwiftUI
import PBAPI
import Models
import UIViews

/// Bank Browser Controller - manages bank browser lifecycle
public class BankBrowserController: ObservableObject {

    /// Current selection (bank, patch)
    @Published public var selectedBankPatch: (Int, Int)? = nil

    /// The MIDI endpoint currently selected for this browser session.
    @Published public var selectedDevice: MIDIPortInfo?

    /// Callback when a patch is selected for editing
    public var onEditTapped: ((Int, Int) -> Void)?

    /// Callback when back is pressed
    public var onBackTapped: (() -> Void)?

    public init(onEditTapped: ((Int, Int) -> Void)? = nil,
                onBackTapped: (() -> Void)? = nil) {
        self.onEditTapped = onEditTapped
        self.onBackTapped = onBackTapped
        // No default selection: nothing has been opened yet.
    }

    /// Handle tap on a bank/patch cell
    public func handleCellTap(_ bank: Int, _ patch: Int) {
        selectedBankPatch = (bank, patch)

        // Notify parent controller
        onEditTapped?(bank, patch)
    }

    /// Handle long press (for context menu or other actions)
    public func handleLongPress(_ bank: Int, _ patch: Int) {
        print("Long press: Bank \(bank), Patch \(patch)")
        // Could show context menu here
    }
}

/// Main application window controller
public class MainWindowController: ObservableObject {

    @Published public var currentView: CurrentView = .bankBrowser

    /// Bank browser controller
    public let bankBrowserController = BankBrowserController()

    // MARK: Bank load state (surfaced in BankBrowserView)
    //
    // This state must live on MainWindowController itself (the object the
    // SwiftUI view hierarchy actually observes via @StateObject), not on a
    // nested ObservableObject: SwiftUI does not forward a child object's
    // @Published changes up through a plain `let` reference, so anything
    // stored on bankBrowserController instead would update silently without
    // ever repainting the view.

    /// True while a 128-program bank dump (~37 KB, 10-30 s over MIDI) is running.
    @Published public var bankLoading: Bool = false
    /// Progress/result text for the bank browser status bar.
    @Published public var bankStatus: String?
    /// The decoded 32512-byte bank, once loaded; selecting a patch slices it.
    @Published private(set) var loadedBank: [UInt8]?
    /// The 128 program names from `loadedBank`.
    @Published private(set) var bankNames: [String] = []
    /// Names for C/D cells, populated lazily as they are read from the synth.
    /// Key 4 = C (64 presets), key 5 = D (64 user slots).
    @Published private(set) var extraBankNames: [Int: [String]] = [:]
    /// Which C/D (bank, patch) cells have actually been read from the
    /// synth at least once — an unread cell's name defaults to "" in
    /// `extraBankNames`, identical to a confirmed-blank cell, so this is
    /// the only way to tell "known empty" apart from "never looked."
    @Published private(set) var extraBankReadSlots: [Int: Set<Int>] = [:]

    /// Where session state (whatever bank was last imported or pulled from
    /// the synth) persists between launches. A `static var`, not a constant,
    /// so tests can redirect it to a temp directory instead of touching the
    /// real one. Defaults to `~/Library/Application Support/MKSoundEditor/`.
    static var sessionStateDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MKSoundEditor", isDirectory: true)
    }()

    private static var sessionBankURL: URL {
        sessionStateDirectory.appendingPathComponent("last-bank.bin")
    }

    public init() {
        // Restore whatever bank was last imported or pulled from the synth,
        // if anything has ever been saved; otherwise fall back to the pinned
        // factory capture so the browser isn't blank at first launch.
        if !loadPersistedSessionBank() {
            loadPinnedBankIfAvailable()
        }

        // Set up navigation between views
        bankBrowserController.onEditTapped = handleBankSelected
        bankBrowserController.onBackTapped = handleBackFromEditor

        // Warm DeviceLocator's cache in the background right away. The slow
        // part of finding the synth is the full candidate-list probe (the
        // UM-ONE isn't Korg-named, so it can sit behind a dozen other MIDI
        // devices); doing that once at launch means Save/Load/Audition hit
        // the cache and respond instantly instead of each paying that cost
        // on whichever one happens to be pressed first.
        DeviceLocator.findDestination { _ in }

        print("MainWindowController initialized")
    }

    /// Bank browser button: pull everything from the synth — the
    /// 128-program A/B dump in one shot, then C and D one slot at a time,
    /// which is the only way this hardware exposes them (see
    /// `PBAPI.SysExHandler.loadExtraProgram`'s doc comment: no bulk SysEx
    /// command reaches C/D). This used to stop after A/B, leaving every
    /// C/D cell reading "(not read yet)" until opened individually in the
    /// editor — "just like A and B" means this one button actually
    /// finishes the job instead of half of it.
    public func loadBankTapped() {
        guard !bankLoading else { return }
        bankLoading = true
        bankStatus = "Finding synthesizer…"
        DeviceLocator.findDestination { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.bankStatus = "Bank load failed: \(error.localizedDescription)"
                    self.bankLoading = false
                case .success(let dest):
                    self.bankStatus = "Requesting 128-program bank (10-45 s)…"
                    PBAPI.SysExHandler.loadBank(deviceID: dest.portRef, timeout: 45) { reply in
                        DispatchQueue.main.async {
                            switch reply {
                            case .success(let bankData):
                                self.loadedBank = bankData
                                self.bankNames = (try? KorgSysEx.programNames(inBank: bankData)) ?? []
                                self.persistSessionBank()
                                // ~128 individual round trips (bank select,
                                // 0.5 s settle, read) — genuinely another
                                // minute or two, no way to parallelize over
                                // one MIDI cable.
                                self.loadExtraBanks(deviceID: dest.portRef, bank: ProgramSlot.bankCount, patch: 0) {
                                    self.bankStatus = "Bank loaded from synth — \(self.bankNames.count) A/B program(s), C/D fully read"
                                    self.bankLoading = false
                                }
                            case .failure(let error):
                                self.bankStatus = "Bank load failed: \(error.localizedDescription)"
                                self.bankLoading = false
                            }
                        }
                    }
                }
            }
        }
    }

    /// Recursively reads every C (bank 4) then D (bank 5) slot one at a
    /// time, updating `extraBankNames`/`extraBankReadSlots` as it goes.
    /// Calls `completion` once D's last slot has been read. A failed
    /// individual read (hardware hiccup, timeout) just leaves that one
    /// slot unknown — moves on rather than aborting the whole sweep over
    /// one bad round trip.
    private func loadExtraBanks(deviceID: UInt32, bank: Int, patch: Int, completion: @escaping () -> Void) {
        guard bank < ProgramSlot.bankCount + 2 else {
            completion()
            return
        }
        guard patch < ProgramSlot.extraPatchesPerBank else {
            loadExtraBanks(deviceID: deviceID, bank: bank + 1, patch: 0, completion: completion)
            return
        }
        bankStatus = "Reading \(ProgramSlot.extraLabel(bank: bank, patch: patch)) (\(patch + 1)/\(ProgramSlot.extraPatchesPerBank))…"
        PBAPI.SysExHandler.loadExtraProgram(
            deviceID: deviceID,
            lsb: ProgramSlot.bankSelectLSB(bank: bank),
            programChange: ProgramSlot.programChange(bank: bank, patch: patch)
        ) { [weak self] reply in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data = try? reply.get(), data.count == KorgSysEx.programDataSize {
                    var names = self.extraBankNames[bank] ?? Array(repeating: "", count: ProgramSlot.extraPatchesPerBank)
                    names[patch] = KorgSysEx.programName(from: Array(data[0..<KorgSysEx.nameLength]))
                    self.extraBankNames[bank] = names
                    self.extraBankReadSlots[bank, default: []].insert(patch)
                }
                self.loadExtraBanks(deviceID: deviceID, bank: bank, patch: patch + 1, completion: completion)
            }
        }
    }

    /// Merge an imported bank into the in-memory bank: only slots the import
    /// actually named are written; every other slot keeps whatever was
    /// already shown (from the synth, the pinned capture, or an earlier
    /// import). A sparse source — e.g. a 10-patch "taster pack" shipped as a
    /// full 128-slot container with the other 118 slots blank — must never
    /// blank out real data that was already loaded.
    public func applyImportedBank(_ bank: [UInt8]) {
        guard bank.count == KorgSysEx.bankDataSize else { return }
        let size = KorgSysEx.programDataSize
        var merged = loadedBank ?? bank
        var mergedCount = 0
        for index in 0..<KorgSysEx.programsPerBank {
            let start = index * size
            let slice = Array(bank[start..<(start + size)])
            guard !KorgSysEx.programName(from: slice).trimmingCharacters(in: .whitespaces).isEmpty else {
                continue
            }
            merged.replaceSubrange(start..<(start + size), with: slice)
            mergedCount += 1
        }
        loadedBank = merged
        bankNames = (try? KorgSysEx.programNames(inBank: merged)) ?? []
        // Only report what THIS import actually changed. The bank is
        // almost always already fully named (factory defaults or an
        // earlier import), so "X of 128 slots now named" was reporting
        // the whole bank's state, not this operation's effect — it said
        // "128 of 128" even when a 10-patch taster pack only touched 10.
        bankStatus = "Imported \(mergedCount) named program(s)"
        persistSessionBank()
    }

    // MARK: Selective import (pick programs, choose destination slots)

    /// One checked import row's chosen destination.
    public struct ImportDestinationAssignment {
        public let program: ProgramFileImport.ImportedProgram
        public let bank: Int
        public let patch: Int
        public init(program: ProgramFileImport.ImportedProgram, bank: Int, patch: Int) {
            self.program = program
            self.bank = bank
            self.patch = patch
        }
    }

    public struct ImportDestinationResult {
        public let succeeded: Int
        public let failures: [(slot: String, reason: String)]
    }

    /// Name currently in a slot, or nil if it's empty (or unknown — a C/D
    /// cell that hasn't been read yet reads as empty, same as a real one;
    /// check `isKnownOccupancy` before treating nil here as "confirmed
    /// empty" for anything consequential, e.g. an import destination).
    public func occupantName(bank: Int, patch: Int) -> String? {
        if ProgramSlot.isExtraBank(bank) {
            guard let names = extraBankNames[bank], patch < names.count, !names[patch].isEmpty else { return nil }
            return names[patch]
        }
        let index = ProgramSlot.index(bank: bank, patch: patch)
        guard index < bankNames.count, !bankNames[index].isEmpty else { return nil }
        return bankNames[index]
    }

    /// True once we actually know what's in this slot — always true for
    /// A/B (`bankNames` is loaded as a complete 128-program dump), true
    /// for a C/D cell only once it's been individually read at least
    /// once. A never-read C/D cell is NOT known to be empty — `nil` from
    /// `occupantName` there means "unknown," not "confirmed empty."
    public func isKnownOccupancy(bank: Int, patch: Int) -> Bool {
        guard ProgramSlot.isExtraBank(bank) else { return true }
        return extraBankReadSlots[bank]?.contains(patch) ?? false
    }

    /// True if putting something in this slot would either silently
    /// overwrite a real existing program, or collide with another checked
    /// row in the same batch aimed at the same destination.
    public func hasConflict(bank: Int, patch: Int, among destinations: [(bank: Int, patch: Int)]) -> Bool {
        let duplicates = destinations.filter { $0.bank == bank && $0.patch == patch }.count
        return duplicates > 1 || occupantName(bank: bank, patch: patch) != nil
    }

    /// Apply a batch of (program, destination) choices from the import
    /// sheet. A/B destinations are pure local state — same as any other
    /// bank edit, no synth required. C/D destinations have no local array
    /// to stage into (same as an editor Save there), so each one is a real,
    /// sequential MIDI write; a failed C/D write doesn't block the rest of
    /// the batch, A/B assignments always succeed regardless of hardware.
    public func applyDestinationAssignments(
        _ assignments: [ImportDestinationAssignment],
        completion: ((ImportDestinationResult) -> Void)? = nil
    ) {
        guard !assignments.isEmpty else {
            completion?(ImportDestinationResult(succeeded: 0, failures: []))
            return
        }
        let abAssignments = assignments.filter { !ProgramSlot.isExtraBank($0.bank) }
        let cdAssignments = assignments.filter { ProgramSlot.isExtraBank($0.bank) }

        for a in abAssignments {
            applySavedProgramLocally(bank: a.bank, patch: a.patch, data: a.program.program.data)
        }

        guard !cdAssignments.isEmpty else {
            bankStatus = "Imported \(abAssignments.count) program(s)"
            completion?(ImportDestinationResult(succeeded: abAssignments.count, failures: []))
            return
        }

        DeviceLocator.findDestination { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    let failures = cdAssignments.map {
                        (slot: ProgramSlot.anyLabel(bank: $0.bank, patch: $0.patch), reason: error.localizedDescription)
                    }
                    self.bankStatus = "Imported \(abAssignments.count) locally — \(cdAssignments.count) C/D write(s) failed: synth not found"
                    completion?(ImportDestinationResult(succeeded: abAssignments.count, failures: failures))
                case .success(let dest):
                    self.writeExtraAssignments(
                        cdAssignments,
                        deviceID: dest.portRef,
                        index: 0,
                        succeeded: abAssignments.count,
                        failures: [],
                        completion: completion
                    )
                }
            }
        }
    }

    /// Sequential C/D writer: one MIDI round trip per program, since the
    /// synth is driven over a single DIN cable and can't take them in
    /// parallel. Recurses to the next assignment regardless of outcome.
    private func writeExtraAssignments(
        _ assignments: [ImportDestinationAssignment],
        deviceID: UInt32,
        index: Int,
        succeeded: Int,
        failures: [(slot: String, reason: String)],
        completion: ((ImportDestinationResult) -> Void)?
    ) {
        guard index < assignments.count else {
            bankStatus = failures.isEmpty
                ? "Imported \(succeeded) program(s)"
                : "Imported \(succeeded) program(s) — \(failures.count) failed"
            completion?(ImportDestinationResult(succeeded: succeeded, failures: failures))
            return
        }
        let a = assignments[index]
        let slotLabel = ProgramSlot.anyLabel(bank: a.bank, patch: a.patch)
        PBAPI.SysExHandler.saveExtraProgram(
            deviceID: deviceID,
            lsb: ProgramSlot.bankSelectLSB(bank: a.bank),
            programChange: ProgramSlot.programChange(bank: a.bank, patch: a.patch),
            data: a.program.program.data
        ) { [weak self] written in
            DispatchQueue.main.async {
                guard let self else { return }
                var nextSucceeded = succeeded
                var nextFailures = failures
                switch written {
                case .success:
                    self.applySavedProgramLocally(bank: a.bank, patch: a.patch, data: a.program.program.data)
                    nextSucceeded += 1
                case .failure(let error):
                    nextFailures.append((slotLabel, error.localizedDescription))
                }
                self.writeExtraAssignments(
                    assignments,
                    deviceID: deviceID,
                    index: index + 1,
                    succeeded: nextSucceeded,
                    failures: nextFailures,
                    completion: completion
                )
            }
        }
    }

    /// Save the current bank to disk so it survives a quit/relaunch. Best
    /// effort — a failed write just means the next launch falls back to
    /// whatever `loadPersistedSessionBank`/`loadPinnedBankIfAvailable` finds.
    private func persistSessionBank() {
        guard let loadedBank else { return }
        let dir = Self.sessionStateDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(loadedBank).write(to: Self.sessionBankURL, options: .atomic)
    }

    /// Restore the bank saved by `persistSessionBank` on a previous run, if
    /// one exists. Returns whether it found and loaded one.
    private func loadPersistedSessionBank() -> Bool {
        guard let data = try? Data(contentsOf: Self.sessionBankURL),
              data.count == KorgSysEx.bankDataSize else { return false }
        let bank = Array(data)
        loadedBank = bank
        bankNames = (try? KorgSysEx.programNames(inBank: bank)) ?? []
        let namedCount = bankNames.filter { !$0.isEmpty }.count
        bankStatus = "Restored \(namedCount) program(s) from last session"
        return true
    }

    /// Writes one program into the grid's state (and persists, for A/B) —
    /// no status message. Split out from `updateSavedProgram` so a bulk
    /// caller can call this N times and announce one final status, instead
    /// of each call clobbering `bankStatus` with its own "Saved X to Y"
    /// message right before the next one overwrites it.
    private func applySavedProgramLocally(bank: Int, patch: Int, data: [UInt8]) {
        if ProgramSlot.isExtraBank(bank) {
            var names = extraBankNames[bank] ?? Array(repeating: "", count: ProgramSlot.extraPatchesPerBank)
            names[patch] = KorgSysEx.programName(from: data)
            extraBankNames[bank] = names
            extraBankReadSlots[bank, default: []].insert(patch)
        } else if var current = loadedBank {
            let index = ProgramSlot.index(bank: bank, patch: patch)
            let start = index * KorgSysEx.programDataSize
            current.replaceSubrange(start..<(start + KorgSysEx.programDataSize), with: data)
            loadedBank = current
            bankNames = (try? KorgSysEx.programNames(inBank: current)) ?? bankNames
            persistSessionBank()
        }
    }

    /// Called after the editor successfully writes a program to the synth.
    /// The editor only talks to hardware over MIDI — without this, the bank
    /// browser's grid and toast never learned a save happened at all, so the
    /// old name stuck around after Back and nothing flashed on save.
    public func updateSavedProgram(bank: Int, patch: Int, data: [UInt8]) {
        guard data.count == KorgSysEx.programDataSize else { return }
        let name = KorgSysEx.programName(from: data)
        let slot = ProgramSlot.isExtraBank(bank)
            ? ProgramSlot.extraLabel(bank: bank, patch: patch)
            : ProgramSlot.label(bank: bank, patch: patch)
        let displayName = name.isEmpty ? slot : name
        applySavedProgramLocally(bank: bank, patch: patch, data: data)
        bankStatus = "Saved \"\(displayName)\" to \(slot)"
    }

    /// Load the pinned factory bank capture if present. This is purely read-only
    /// and gives the browser names without requiring the synth to be connected.
    private func loadPinnedBankIfAvailable() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("dev/MKSoundEditor/bank-capture.syx")
        guard let data = try? Data(contentsOf: url) else { return }
        guard let programs = try? ProgramFileImport.programs(from: Array(data)),
              programs.count == KorgSysEx.programsPerBank else { return }
        // Reuse the already-decoded program bytes rather than re-deriving the
        // bank from the raw (still SysEx-framed) file: KorgSysEx.bank(fromAllData:)
        // expects a decoded 0x50 payload, not the raw .syx bytes.
        let bank = programs.flatMap { $0.program.data }
        loadedBank = bank
        bankNames = (try? KorgSysEx.programNames(inBank: bank)) ?? []
        bankStatus = "Factory bank loaded from disk — \(bankNames.count) programs"
    }

    private func handleBankSelected(_ bank: Int, _ patch: Int) {
        // C/D cells sit beyond the dump: bank-select on the synth, then read
        // the edit buffer (HANDOFF-v10 §2a). The save path uses the same
        // bank-select plus an unaddressed 0x11 write to commit.
        if ProgramSlot.isExtraBank(bank) {
            loadExtraCell(bank, patch)
            return
        }

        let slot = ProgramSlot.label(bank: bank, patch: patch)
        // Fast path: the bank is already in memory — slice the exact
        // 254 bytes for this cell and hand them straight to the editor.
        let index = ProgramSlot.index(bank: bank, patch: patch)
        if index < KorgSysEx.programsPerBank,
           let loadedBank,
           let program = try? KorgSysEx.program(index, inBank: loadedBank) {
            currentView = .editor(bankNumber: bank, patchNumber: patch, rawData: program)
            return
        }

        // Slow path: no bank cached (or cell beyond the 128-program bank) —
        // read the synth's edit buffer so the editor still opens on real bytes.
        currentView = .loading(message: "Loading \(slot) from synthesizer…")
        DeviceLocator.findDestination { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure:
                    // No hardware reachable: open empty; the editor's Load
                    // button reports the underlying error when pressed.
                    self.currentView = .editor(bankNumber: bank, patchNumber: patch, rawData: [])
                case .success(let dest):
                    PBAPI.SysExHandler.loadCurrentProgram(deviceID: dest.portRef) { reply in
                        DispatchQueue.main.async {
                            let data = (try? reply.get()) ?? []
                            self.currentView = .editor(
                                bankNumber: bank,
                                patchNumber: patch,
                                rawData: data
                            )
                        }
                    }
                }
            }
        }
    }

    private func handleBackFromEditor() {
        print("Returning to bank browser")
        currentView = .bankBrowser
    }

    // MARK: C/D cells (browse-only, HANDOFF-v10 §2a)
    //
    // C and D are not in the 0x0F dump. Reaching one means bank select
    // (CC32=1, PC 0...63 for C / 64...127 for D) then an edit buffer read.
    // That changes the synth's SELECTED program but stores nothing, so this
    // is safe to drive; the editor opens read-only for these cells.

    private func loadExtraCell(_ bank: Int, _ patch: Int) {
        let label = ProgramSlot.extraLabel(bank: bank, patch: patch)
        currentView = .loading(message: "Loading \(label) from synthesizer…")

        DeviceLocator.findDestination { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure:
                    // No hardware: open empty so the editor still shows the
                    // slot; its Load button reports why.
                    self.currentView = .editor(
                        bankNumber: bank,
                        patchNumber: patch,
                        rawData: []
                    )
                case .success(let dest):
                    PBAPI.SysExHandler.loadExtraProgram(
                        deviceID: dest.portRef,
                        lsb: ProgramSlot.bankSelectLSB(bank: bank),
                        programChange: ProgramSlot.programChange(bank: bank, patch: patch)
                    ) { reply in
                        DispatchQueue.main.async {
                            let data = (try? reply.get()) ?? []
                            if data.count == KorgSysEx.programDataSize {
                                var names = self.extraBankNames[bank] ?? Array(repeating: "", count: ProgramSlot.extraPatchesPerBank)
                                names[patch] = KorgSysEx.programName(from: Array(data[0..<KorgSysEx.nameLength]))
                                self.extraBankNames[bank] = names
                                self.extraBankReadSlots[bank, default: []].insert(patch)
                            }
                            self.currentView = .editor(
                                bankNumber: bank,
                                patchNumber: patch,
                                rawData: data
                            )
                        }
                    }
                }
            }
        }
    }
}

/// Current view enum for navigation
public enum CurrentView {
    case bankBrowser
    case loading(message: String)
    case editor(bankNumber: Int, patchNumber: Int, rawData: [UInt8])

    public var title: String {
        switch self {
        case .bankBrowser:
            return "Bank Browser"
        case .loading:
            return "Loading"
        case .editor:
            return "Edit Patch"
        }
    }
}

// MARK: - View Wrapper

extension MainWindowController {

    public func asView() -> some View {
        NavigationStack {
            switch currentView {
            case .bankBrowser:
                BankBrowserView(
                    onEditTapped: bankBrowserController.onEditTapped,
                    onLoadBankTapped: { [weak self] in self?.loadBankTapped() },
                    onBankImported: { [weak self] bank in self?.applyImportedBank(bank) },
                    onProgramImported: { [weak self] imported in
                        // No slot context for a lone .prg import: open it at
                        // A.11 for preview/audition. Save still writes for
                        // real, so the slot label makes that destination explicit.
                        self?.currentView = .editor(bankNumber: 0, patchNumber: 0, rawData: imported.program.data)
                    },
                    onImportAssignments: { [weak self] assignments in
                        self?.applyDestinationAssignments(
                            assignments.map {
                                ImportDestinationAssignment(program: $0.program, bank: $0.bank, patch: $0.patch)
                            }
                        )
                    },
                    occupantName: { [weak self] bank, patch in self?.occupantName(bank: bank, patch: patch) },
                    isKnownOccupancy: { [weak self] bank, patch in self?.isKnownOccupancy(bank: bank, patch: patch) ?? true },
                    isLoadingBank: bankLoading,
                    bankStatus: bankStatus,
                    programNames: bankNames,
                    extraProgramNames: extraBankNames
                )

            case .loading(let message):
                VStack(spacing: 16) {
                    ProgressView()
                    Text(message)
                        .font(.custom("GolosText-Regular", size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .editor(let bank, let patch, let rawData):
                EditorView(
                    bankNumber: bank,
                    patchNumber: patch,
                    rawData: rawData,
                    // Returns to the bank browser instead of closing the window.
                    onBack: bankBrowserController.onBackTapped,
                    onSaved: { [weak self] bank, patch, data in
                        self?.updateSavedProgram(bank: bank, patch: patch, data: data)
                    }
                )
            }
        }
        .navigationTitle(currentView.title)
    }
}

#Preview {
    MainWindowController()
        .asView()
}
