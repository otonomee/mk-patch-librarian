import SwiftUI
import AppKit
import Models
import PBAPI

/// Cool palette for this sheet only — scoped here, not merged into the
/// shared `PatchTheme` (the editor's amber/charcoal palette elsewhere is
/// a separate, already-approved look; this sheet's old amber "selected
/// row" and all-red occupied-slot text were specific complaints about
/// this file, not a request to re-theme the whole app).
private enum ImportPalette {
    static let powderBlush = Color(red: 0xff / 255.0, green: 0xa6 / 255.0, blue: 0x9e / 255.0)
    static let eggshell = Color(red: 0xfa / 255.0, green: 0xf3 / 255.0, blue: 0xdd / 255.0)
    static let icyAqua = Color(red: 0xb8 / 255.0, green: 0xf2 / 255.0, blue: 0xe6 / 255.0)
    static let lightBlue = Color(red: 0xae / 255.0, green: 0xd9 / 255.0, blue: 0xe0 / 255.0)
    static let blueSlate = Color(red: 0x5e / 255.0, green: 0x64 / 255.0, blue: 0x72 / 255.0)
    static let deepSpaceBlue = Color(red: 0x17 / 255.0, green: 0x2a / 255.0, blue: 0x3a / 255.0)
}

/// Golos Text for general UI text, JetBrains Mono for patch slot IDs —
/// same split and bundling as BrowserFont/SettingsFont. Scoped to this
/// screen like the palette above.
private enum ImportFont {
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .heavy, .black: name = "GolosText-Black"
        case .bold: name = "GolosText-Bold"
        case .semibold: name = "GolosText-SemiBold"
        case .medium: name = "GolosText-Medium"
        default: name = "GolosText-Regular"
        }
        return .custom(name, size: size)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(weight == .regular ? "JetBrainsMono-Regular" : "JetBrainsMono-SemiBold", size: size)
    }
}

/// Sheet for importing microKORG program files (.prg, .set, .syx).
public struct ImportProgramsView: View {

    /// Called when the user imports one or more programs. The first program
    /// is also surfaced as a full 254-byte bank if the source was a `.set`.
    public var onImported: (([ProgramFileImport.ImportedProgram], [UInt8]?) -> Void)?

    /// Called when the user checks one or more programs and picks a
    /// destination slot for each, then taps "Import Selected". Each
    /// (bank, patch) pair uses the same addressing as everywhere else in
    /// the app (A/B split into two 32-slot halves, C/D as banks 4/5).
    public var onImportSelected: (([(program: ProgramFileImport.ImportedProgram, bank: Int, patch: Int)]) -> Void)?

    /// What's currently in a slot, or nil if it's empty — used to preview
    /// and flag conflicts before the import actually happens.
    public var occupantName: ((Int, Int) -> String?)?

    /// True once a slot's occupancy is actually known (always true for
    /// A/B; only true for a C/D slot that's been individually read).
    /// `occupantName` returning nil for a slot this says is NOT known is
    /// "unknown," not "confirmed empty" — auto-assign must never treat
    /// that as safe to silently fill. Defaults to "always known" so a
    /// caller that doesn't pass this (tests, previews) keeps the old
    /// occupantName-only behavior instead of refusing every slot.
    public var isKnownOccupancy: ((Int, Int) -> Bool)?

    /// Called after a successful import, with the destination (bank, patch),
    /// when "Open in editor after importing" was checked and exactly one
    /// program was imported.
    public var onOpenAfterImport: ((Int, Int) -> Void)?

    /// Called to dismiss the sheet.
    public var onDismiss: () -> Void

    /// A file already dropped on the Bank Browser before this sheet opened —
    /// when set, skip the picker and load it directly.
    public var preloadedURL: URL?

    /// A checked program's chosen destination, before resolving into the
    /// app's internal bank/patch addressing.
    private struct Destination: Equatable {
        var letter: Int
        var slot: Int
    }

    @State private var imported: [ProgramFileImport.ImportedProgram] = []
    @State private var importedBank: [UInt8]?
    @State private var status: String? = nil
    @State private var isImporting = false
    @State private var selectedIDs: Set<ProgramFileImport.ImportedProgram.ID> = []
    /// Manual overrides only — the baseline comes from `autoAssignments`.
    @State private var destinations: [ProgramFileImport.ImportedProgram.ID: Destination] = [:]
    @State private var openAfterImport = false
    /// Which bank the Destination Map's slot list is currently showing —
    /// shared across the whole map, not per-program.
    @State private var activeBank = 0
    /// The slot (within `activeBank`) whose reassign/remove popover is open.
    @State private var popoverSlot: Int?

    /// Memoized `autoAssignments`/`importedByID` — both are recomputed only
    /// when `selectedIDs`, `destinations`, or `imported` actually change,
    /// not on every call. Without this, a full 128-program bank import
    /// hung at ~95% CPU: `destination(for:)` is called from every row on
    /// every render, and each call used to redo the whole O(slots × n)
    /// auto-assignment scan from scratch (plus an O(n) linear `imported`
    /// lookup per call on top of that) — live-measured at roughly 5×10⁸
    /// steps for a full bank.
    @State private var cachedAutoAssignments: [ProgramFileImport.ImportedProgram.ID: Destination] = [:]
    @State private var importedByID: [ProgramFileImport.ImportedProgram.ID: ProgramFileImport.ImportedProgram] = [:]

    public init(
        onImported: (([ProgramFileImport.ImportedProgram], [UInt8]?) -> Void)? = nil,
        onImportSelected: (([(program: ProgramFileImport.ImportedProgram, bank: Int, patch: Int)]) -> Void)? = nil,
        occupantName: ((Int, Int) -> String?)? = nil,
        isKnownOccupancy: ((Int, Int) -> Bool)? = nil,
        onOpenAfterImport: ((Int, Int) -> Void)? = nil,
        preloadedURL: URL? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.onImported = onImported
        self.onImportSelected = onImportSelected
        self.occupantName = occupantName
        self.isKnownOccupancy = isKnownOccupancy
        self.onOpenAfterImport = onOpenAfterImport
        self.preloadedURL = preloadedURL
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Import Programs")
                    .font(ImportFont.sans(17, weight: .bold))
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.escape, modifiers: [])
                    .pointerCursor()
            }
            // Extra clearance above the header row: the sheet's own
            // rounded-corner clip mask shaves pixels off anything sitting
            // close to the top-left/top-right corners — "Import Programs"
            // sits at the leading edge, "Done" at the trailing edge, so
            // both need real vertical clearance to clear the curve, not
            // just a token few points.
            .padding(.top, 20)

            if let status {
                HStack(spacing: 8) {
                    if isImporting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(status)
                        .font(ImportFont.sans(13))
                        .foregroundColor(.secondary)
                }
            }

            if !imported.isEmpty {
                // Split pane: a plain checklist of what's being imported
                // (left) against one shared, always-visible map of the
                // synth's memory (right) — replaces the old one-full-card-
                // per-selected-program stack, which meant scrolling past a
                // whole bank-tabs-and-slot-list card per file just to see
                // the next one. Auto-assign fills the map in immediately
                // (next empty slot per checked file); click any row to
                // reassign or remove via the popover.
                HStack(alignment: .top, spacing: 16) {
                    sourceQueue()
                        .frame(width: 260)
                    destinationMap()
                        .frame(maxWidth: .infinity)
                }

                HStack(spacing: 10) {
                    actionButton("Select All", icon: "checkmark.circle", disabled: imported.isEmpty) {
                        selectedIDs = Set(imported.map(\.id))
                    }

                    actionButton(importButtonTitle, icon: "tray.and.arrow.down", prominent: true, disabled: selectedIDs.isEmpty) {
                        performImport()
                    }
                    .help("Imports every checked program above, each to the slot you picked for it")

                    if selectedIDs.count == 1 {
                        Toggle("Open in editor after importing", isOn: $openAfterImport)
                            .toggleStyle(.checkbox)
                            .font(ImportFont.sans(12))
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 820, minHeight: 320)
        .onAppear {
            // Opening this sheet (toolbar click, or a file dropped on the
            // Bank Browser) already means "I want to import a file" — go
            // straight to the picker (or the dropped file) instead of
            // making the user click a second, identically-worded button
            // inside the sheet to actually start. There's no retry button
            // in here on purpose; cancelling the picker and wanting another
            // file means closing this sheet and reopening from the toolbar.
            guard imported.isEmpty && !isImporting else { return }
            if let preloadedURL {
                loadFile(from: preloadedURL)
            } else {
                // NSOpenPanel.runModal() called synchronously from within
                // .onAppear doesn't reliably present — the sheet's own
                // presentation animation hasn't finished, so the panel can
                // silently no-op. Deferring one runloop tick is the
                // standard fix; it's invisible at normal interaction speed.
                // That tick (plus however long AppKit takes to actually
                // raise the panel) is a real, visible gap with an otherwise
                // completely blank sheet — show the spinner immediately
                // instead of only once a file's being read.
                isImporting = true
                status = "Opening file picker…"
                DispatchQueue.main.async {
                    pickFile()
                }
            }
        }
        .onChange(of: selectedIDs) { _, _ in recomputeAssignmentCaches() }
        .onChange(of: destinations) { _, _ in recomputeAssignmentCaches() }
    }

    private var importButtonTitle: String {
        guard !selectedIDs.isEmpty else { return "Import" }
        let conflicts = selectedIDs.filter { isConflicting(destinationFor($0)) }.count
        let noun = selectedIDs.count == 1 ? "Program" : "Programs"
        return conflicts > 0
            ? "Import \(selectedIDs.count) \(noun) (\(conflicts) will overwrite)"
            : "Import \(selectedIDs.count) \(noun)"
    }

    /// Everything selected and this is a full `.set`/bank dump → one bulk
    /// whole-bank write at each program's original slot (what "Import All"
    /// used to do). Otherwise → per-program writes to whatever slot each
    /// one's destination picker says (what "Import Checked" used to do).
    /// Collapsing both into one button this way keeps both code paths —
    /// the fast bulk path still fires for the common "take the whole file"
    /// case — without asking the user to pick between two buttons that
    /// mean nearly the same thing.
    private func performImport() {
        let openTarget: (bank: Int, patch: Int)? = selectedIDs.count == 1
            ? selectedIDs.first.map(destinationFor)
            : nil

        if let importedBank, selectedIDs.count == imported.count {
            onImported?(imported, importedBank)
        } else {
            onImportSelected?(selectedAssignments())
        }

        if openAfterImport, let openTarget {
            onOpenAfterImport?(openTarget.bank, openTarget.patch)
        }
        onDismiss()
    }

    /// Left pane: just the checklist, no per-row destination — picking a
    /// slot lives entirely in `destinationMap()` now. Format is deliberately
    /// bare (checkbox + name only): the old slot-number column showed every
    /// standalone `.prg`'s meaningless placeholder sourceIndex as the same
    /// fake "A.11" on every row, which this shape sidesteps entirely rather
    /// than patching further.
    @ViewBuilder
    private func sourceQueue() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source Queue")
                .font(ImportFont.sans(11, weight: .semibold))
                .foregroundColor(.secondary)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(imported) { program in
                        HStack(spacing: 10) {
                            Toggle("", isOn: checkedBinding(for: program.id))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                            Text(program.name)
                                .font(ImportFont.sans(13))
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            checkedBinding(for: program.id).wrappedValue.toggle()
                        }
                        .pointerCursor()
                    }
                }
            }
            .frame(height: 340)
            .background(PatchTheme.windowBG.opacity(0.3))
        }
    }

    /// Right pane: one shared, always-visible map of the synth's memory —
    /// bank tabs + a scrollable slot list for whichever bank is active.
    /// Replaces a full bank-tabs-and-slot-list card per selected program;
    /// every checked file auto-assigns into the next empty slot as soon as
    /// it's checked (see `autoAssignments`), so the map is populated
    /// immediately instead of needing N separate pickers worked through
    /// one at a time.
    @ViewBuilder
    private func destinationMap() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Destination Map")
                    .font(ImportFont.sans(11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Picker("", selection: $activeBank) {
                    ForEach(0..<ProgramSlot.letterCount, id: \.self) { letter in
                        Text(ProgramSlot.bankLetter(letter)).tag(letter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .tint(ImportPalette.lightBlue)
                .frame(width: 160)
                .pointerCursor()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(0..<ProgramSlot.slotsPerLetter, id: \.self) { slot in
                            slotRow(slot).id(slot)
                        }
                    }
                }
                .frame(height: 340)
                .background(PatchTheme.windowBG.opacity(0.5))
                .onAppear { navigateToFirstAssignment(proxy: proxy) }
                .onChange(of: activeBank) { _, _ in scrollToFirstAssignment(in: activeBank, proxy: proxy) }
                .onChange(of: selectedIDs) { _, _ in scrollToFirstAssignment(in: activeBank, proxy: proxy) }
            }
        }
    }

    /// First appearance only: bank A (the default `activeBank`) is often
    /// already full on a synth that's been used a while, in which case
    /// every checked file auto-assigns somewhere past it — confirmed live
    /// with 10 files that all landed in bank C while A and B were full,
    /// with nothing on-screen to suggest looking there. Jump the active
    /// bank itself to wherever the assignments actually are, once, so
    /// there's never a load that looks like nothing happened.
    private func navigateToFirstAssignment(proxy: ScrollViewProxy) {
        if firstAssignedSlot(in: activeBank) != nil {
            scrollToFirstAssignment(in: activeBank, proxy: proxy)
            return
        }
        guard let bankWithAssignments = (0..<ProgramSlot.letterCount).first(where: { firstAssignedSlot(in: $0) != nil }) else { return }
        activeBank = bankWithAssignments
        // The resulting change fires the .onChange below, which scrolls
        // once that bank's rows exist.
    }

    /// Re-centers on whatever's assigned within `bank` — never changes
    /// which bank is showing. Manual navigation to a bank with nothing
    /// assigned (to hand-pick a slot there via the popover, say) has to
    /// stay put, not get silently redirected back to wherever the
    /// auto-assignments are.
    private func scrollToFirstAssignment(in bank: Int, proxy: ScrollViewProxy) {
        guard let slot = firstAssignedSlot(in: bank) else { return }
        // Calling scrollTo in the same tick .onAppear/.onChange fires in
        // silently no-ops here — the 64-row VStack hasn't finished laying
        // out yet. Same class of issue as the NSOpenPanel-from-.onAppear
        // fix elsewhere in this file; same fix, one runloop tick later.
        DispatchQueue.main.async {
            withAnimation {
                proxy.scrollTo(slot, anchor: .center)
            }
        }
    }

    private func firstAssignedSlot(in bank: Int) -> Int? {
        (0..<ProgramSlot.slotsPerLetter).first { slot in
            imported.contains {
                selectedIDs.contains($0.id)
                    && destination(for: $0).letter == bank
                    && destination(for: $0).slot == slot
            }
        }
    }

    @ViewBuilder
    private func slotRow(_ slot: Int) -> some View {
        let resolved = ProgramSlot.resolve(letter: activeBank, slot: slot)
        let existingOccupant = occupantName?(resolved.bank, resolved.patch)
        // A C/D slot that's never been individually read also reads nil
        // from occupantName, same as a genuinely blank one — "(empty)"
        // would claim certainty this app doesn't have. Only ever false
        // for an unread C/D cell; A/B are always known.
        let isKnown = isKnownOccupancy?(resolved.bank, resolved.patch) ?? true
        let assignedProgram = imported.first {
            selectedIDs.contains($0.id)
                && destination(for: $0).letter == activeBank
                && destination(for: $0).slot == slot
        }
        // Only an assigned slot that's *also* already occupied is an
        // actual overwrite about to happen — an assigned-but-empty slot
        // (the common case) just gets the calm "here's what's landing
        // here" highlight, and a merely-occupied, unassigned slot is pure
        // information, not a warning.
        let isOverwrite = assignedProgram != nil && existingOccupant != nil

        HStack(spacing: 8) {
            Text(ProgramSlot.letterSlotLabel(slot))
                .font(ImportFont.mono(12.5))
                .foregroundColor(ImportPalette.blueSlate)
                .frame(width: 26, alignment: .leading)

            if let assignedProgram {
                Text("\u{2192} \(assignedProgram.name)")
                    .font(ImportFont.sans(12.5, weight: .semibold))
                    .foregroundColor(isOverwrite ? ImportPalette.powderBlush : ImportPalette.icyAqua)
                    .lineLimit(1)
            } else {
                Text(existingOccupant ?? (isKnown ? "(empty)" : "(not read yet)"))
                    .font(ImportFont.sans(12.5, weight: existingOccupant != nil ? .semibold : .regular))
                    .italic(!isKnown)
                    .foregroundColor(existingOccupant != nil ? ImportPalette.eggshell : ImportPalette.blueSlate)
                    .lineLimit(1)
            }

            Spacer()

            if isOverwrite, let existingOccupant {
                Text("Overwrites \u{201C}\(existingOccupant)\u{201D}")
                    .font(ImportFont.sans(10.5, weight: .medium))
                    .foregroundColor(ImportPalette.powderBlush)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            isOverwrite ? ImportPalette.powderBlush.opacity(0.18)
                : assignedProgram != nil ? ImportPalette.icyAqua.opacity(0.18)
                : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture { popoverSlot = slot }
        .pointerCursor()
        .popover(isPresented: Binding(
            get: { popoverSlot == slot },
            set: { isPresented in if !isPresented { popoverSlot = nil } }
        )) {
            slotPopover(slot: slot)
        }
    }

    /// "Replace with: [dropdown of imported files] | Remove", per the
    /// design brief. Picking a different file for an already-assigned slot
    /// clears the previous occupant's manual destination (reverting it to
    /// auto-assign elsewhere) instead of leaving both pointed at the same
    /// slot as a silent duplicate. "Remove" unchecks the file entirely —
    /// a checked file always has *some* destination in this model, so
    /// clearing a slot's assignment and leaving it checked with nowhere to
    /// go isn't a state worth representing.
    @ViewBuilder
    private func slotPopover(slot: Int) -> some View {
        let current = imported.first {
            selectedIDs.contains($0.id)
                && destination(for: $0).letter == activeBank
                && destination(for: $0).slot == slot
        }

        VStack(alignment: .leading, spacing: 10) {
            Text("Slot \(ProgramSlot.letterSlotLabel(slot))")
                .font(ImportFont.sans(12, weight: .semibold))

            Picker("Replace with", selection: Binding<ProgramFileImport.ImportedProgram.ID?>(
                get: { current?.id },
                set: { newID in
                    if let oldID = current?.id, oldID != newID {
                        destinations.removeValue(forKey: oldID)
                    }
                    guard let newID else { return }
                    destinations[newID] = Destination(letter: activeBank, slot: slot)
                }
            )) {
                Text("\u{2014} None \u{2014}").tag(Optional<ProgramFileImport.ImportedProgram.ID>.none)
                ForEach(imported.filter { selectedIDs.contains($0.id) }) { program in
                    Text(program.name).tag(Optional(program.id))
                }
            }
            .labelsHidden()
            .frame(width: 200)
            .pointerCursor()

            if let current {
                Button("Remove", role: .destructive) {
                    selectedIDs.remove(current.id)
                    destinations.removeValue(forKey: current.id)
                    popoverSlot = nil
                }
                .pointerCursor()
            }
        }
        .padding(12)
        .frame(width: 224)
    }

    // MARK: Destination state

    /// Baseline destinations for every checked program that doesn't have a
    /// manual override: walk bank A→D, slot 1→64 in order, skipping
    /// already-occupied synth slots, slots whose occupancy isn't actually
    /// known yet (an unread C/D cell — occupantName reading nil there
    /// means "unknown," not "confirmed empty," and auto-assign must never
    /// land there unattended), and slots already claimed (by a manual
    /// override or an earlier program in this same pass), and hand each
    /// remaining checked program the next free one. A checked program with
    /// a manual override (from the popover) never appears here — this is
    /// only ever the fallback. The popover itself has no such restriction:
    /// a user who already knows a C slot is blank can still hand-assign
    /// it there, same as before.
    /// Recomputes `cachedAutoAssignments`/`importedByID` from scratch —
    /// called once per actual state change (see the `.onChange`s on body),
    /// never from inside a per-row accessor. Body/logic unchanged from the
    /// original computed property; only *when* it runs changed.
    private func recomputeAssignmentCaches() {
        importedByID = Dictionary(uniqueKeysWithValues: imported.map { ($0.id, $0) })

        let totalSlots = ProgramSlot.letterCount * ProgramSlot.slotsPerLetter
        var claimed = Set(
            destinations
                .filter { selectedIDs.contains($0.key) }
                .map { $0.value.letter * ProgramSlot.slotsPerLetter + $0.value.slot }
        )
        var result: [ProgramFileImport.ImportedProgram.ID: Destination] = [:]

        for program in imported where selectedIDs.contains(program.id) && destinations[program.id] == nil {
            var flat = 0
            while flat < totalSlots {
                defer { flat += 1 }
                guard !claimed.contains(flat) else { continue }
                let letter = flat / ProgramSlot.slotsPerLetter
                let slot = flat % ProgramSlot.slotsPerLetter
                let resolved = ProgramSlot.resolve(letter: letter, slot: slot)
                guard occupantName?(resolved.bank, resolved.patch) == nil,
                      isKnownOccupancy?(resolved.bank, resolved.patch) ?? true else { continue }
                claimed.insert(flat)
                result[program.id] = Destination(letter: letter, slot: slot)
                break
            }
            // If every slot is either occupied or already claimed (more
            // checked files than free slots exist), this program is left
            // without an auto-assignment — `destination(for:)` falls back
            // to A.01, and the resulting duplicate is caught by
            // `isConflicting` same as any other collision.
        }
        cachedAutoAssignments = result
    }

    private func destination(for program: ProgramFileImport.ImportedProgram) -> Destination {
        destinations[program.id] ?? cachedAutoAssignments[program.id] ?? Destination(letter: 0, slot: 0)
    }

    private func destinationFor(_ id: ProgramFileImport.ImportedProgram.ID) -> (bank: Int, patch: Int) {
        guard let program = importedByID[id] else { return (0, 0) }
        let dest = destination(for: program)
        return ProgramSlot.resolve(letter: dest.letter, slot: dest.slot)
    }

    private func checkedBinding(for id: ProgramFileImport.ImportedProgram.ID) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { isOn in
                if isOn { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
            }
        )
    }

    /// Every destination currently chosen among the checked rows — used to
    /// flag two rows aimed at the same slot, not just an already-occupied one.
    private var selectedDestinations: [(bank: Int, patch: Int)] {
        selectedIDs.map(destinationFor)
    }

    private func isConflicting(_ target: (bank: Int, patch: Int)) -> Bool {
        let duplicates = selectedDestinations.filter { $0.bank == target.bank && $0.patch == target.patch }.count
        return duplicates > 1 || occupantName?(target.bank, target.patch) != nil
    }

    private func selectedAssignments() -> [(program: ProgramFileImport.ImportedProgram, bank: Int, patch: Int)] {
        selectedIDs.compactMap { id in
            guard let program = importedByID[id] else { return nil }
            let dest = destination(for: program)
            let resolved = ProgramSlot.resolve(letter: dest.letter, slot: dest.slot)
            return (program, resolved.bank, resolved.patch)
        }
    }

    /// Icon + text button, fixed-size so its label never auto-truncates the
    /// way the native `.bordered` Button style did in this tight sheet.
    @ViewBuilder
    private func actionButton(
        _ title: String,
        icon: String,
        prominent: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        // Disabled dims the TEXT only — fading the whole button (chrome
        // included) to ~40% opacity made every disabled label unreadable
        // against the dark background, and a half-opacity amber "prominent"
        // button just looked broken. The prominent background only ever
        // appears once the action is actually available.
        let isProminent = prominent && !disabled
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(ImportFont.sans(12, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .foregroundColor(
            disabled ? PatchTheme.dustGrey.opacity(0.35)
                : isProminent ? ImportPalette.deepSpaceBlue : PatchTheme.dustGrey
        )
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isProminent ? ImportPalette.icyAqua : PatchTheme.cardBG)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(PatchTheme.cardBorder, lineWidth: 1)
        )
        .disabled(disabled)
        .pointerCursor()
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [] // Accept any; filter by extension in logic.
        panel.title = "Import microKORG Programs"

        guard panel.runModal() == .OK, !panel.urls.isEmpty else {
            // No retry button in this sheet (see .onAppear) — cancelling
            // just leaves it idle; closing and reopening from the toolbar
            // is how you try again.
            isImporting = false
            status = nil
            return
        }
        loadFiles(from: panel.urls)
    }

    private func loadFile(from url: URL) {
        loadFiles(from: [url])
    }

    private func loadFiles(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        status = urls.count == 1
            ? "Reading \(urls[0].lastPathComponent)…"
            : "Reading \(urls.count) files…"

        DispatchQueue.global(qos: .userInitiated).async {
            var allNamed: [ProgramFileImport.ImportedProgram] = []
            // The "whole bank, original slots" fast path only makes sense
            // for a single full-bank file — multiple files selected at
            // once have no single "original slot" layout to fall back to,
            // so they always go through the per-program chosen-slot path.
            var singleFileBank: [UInt8]?
            var failures: [(file: String, message: String)] = []

            for url in urls {
                do {
                    let data = Array(try Data(contentsOf: url))
                    let programs = try ProgramFileImport.programs(from: data)

                    // If the source was a full bank dump, concatenate the
                    // already-decoded programs into bank bytes so the
                    // browser can display all 128 cells. (KorgSysEx.bank(
                    // fromAllData:) expects an already-decoded 0x50
                    // payload, not the raw file bytes — reuse what
                    // `programs` already parsed instead.) This keeps every
                    // slot, named or blank: the merge in
                    // applyImportedBank needs to see the blanks too, to
                    // know which slots NOT to touch.
                    if urls.count == 1, programs.count == KorgSysEx.programsPerBank {
                        singleFileBank = programs
                            .sorted { $0.sourceIndex < $1.sourceIndex }
                            .flatMap { $0.program.data }
                    }

                    // A `.set`/full-bank source is a fixed 128-slot
                    // container; most vendor "taster pack" files only
                    // populate a handful of slots and leave the rest as
                    // blank defaults. Only the named ones are real sounds —
                    // don't show or count the blanks, and don't let "Open
                    // First Program" land on one.
                    let named = programs.filter {
                        !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
                    }
                    allNamed.append(contentsOf: named)
                } catch {
                    failures.append((url.lastPathComponent, error.localizedDescription))
                }
            }

            DispatchQueue.main.async {
                self.imported = allNamed
                self.importedBank = singleFileBank
                // Default to everything selected: the single-program case
                // (by far the common one, e.g. a dropped .prg) is then one
                // click away from imported instead of needing a row click
                // first. "Select All" brings this back after narrowing
                // down to inspect a single row, which a plain click on a
                // row replaces the selection with.
                self.selectedIDs = Set(allNamed.map(\.id))
                self.destinations = [:]
                self.activeBank = 0
                self.popoverSlot = nil
                self.recomputeAssignmentCaches()
                // Parsing isn't applying: nothing reaches the browser or
                // editor until the user taps one of the action buttons.
                // A single `.prg` isn't "programs from" a container — name
                // it directly. Only a multi-program `.set`/bank dump, or
                // more than one file, reads as "N programs from <source>".
                let failureSuffix = failures.isEmpty ? "" : " — \(failures.count) file(s) failed: \(failures.map(\.file).joined(separator: ", "))"
                if allNamed.isEmpty, !failures.isEmpty {
                    self.status = "Import failed: \(failures.map { "\($0.file): \($0.message)" }.joined(separator: "; "))"
                } else if urls.count == 1, let only = allNamed.first, allNamed.count == 1 {
                    self.status = "Loaded \u{201C}\(only.name)\u{201D} — choose an action below"
                } else if urls.count == 1 {
                    self.status = "Read \(allNamed.count) programs from \(urls[0].lastPathComponent) — choose an action below"
                } else {
                    self.status = "Read \(allNamed.count) programs from \(urls.count) files\(failureSuffix) — choose an action below"
                }
                self.isImporting = false
            }
        }
    }
}
