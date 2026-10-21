import SwiftUI
import AppKit
import Models
import PBAPI
import UniformTypeIdentifiers

/// Cool-blue palette for this screen only — scoped here, not merged into
/// the shared `PatchTheme` (the editor's charcoal/icy-aqua look is a
/// separate, already-approved identity; this is the Bank Browser's own
/// brand treatment per the design brief, same scoping choice as
/// ImportProgramsView.ImportPalette).
private enum BrowserPalette {
    // Toned down from the brief's literal #172a3a/#1f3548 — those read as
    // saturated navy at this much screen coverage ("too blue, vibecoded").
    // Same family, much lower saturation: neutral graphite with just a
    // faint cool edge, closer to a serious dev tool than a SaaS dashboard.
    static let deepSpaceBlue = Color(red: 0x21 / 255.0, green: 0x25 / 255.0, blue: 0x2b / 255.0)
    static let cardBG = Color(red: 0x2b / 255.0, green: 0x30 / 255.0, blue: 0x38 / 255.0)
    static let icyAqua = Color(red: 0xb8 / 255.0, green: 0xf2 / 255.0, blue: 0xe6 / 255.0)
    static let eggshell = Color(red: 0xfa / 255.0, green: 0xf3 / 255.0, blue: 0xdd / 255.0)
    static let mintLeaf = Color(red: 0x09 / 255.0, green: 0xbc / 255.0, blue: 0x8a / 255.0)
    static let blueSlate = Color(red: 0x5e / 255.0, green: 0x64 / 255.0, blue: 0x72 / 255.0)
}

/// Inter for general UI text, JetBrains Mono for patch slot IDs — bundled
/// as static TTFs under Resources/Fonts, registered via the app bundle's
/// ATSApplicationFontsPath (see bundle.sh), no system-wide install needed.
/// Scoped to this screen like the palette above.
private enum BrowserFont {
    static func inter(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Inter-ExtraBold"
        case .semibold: name = "Inter-SemiBold"
        case .medium: name = "Inter-Medium"
        default: name = "Inter-Regular"
        }
        return .custom(name, size: size)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "JetBrainsMono-Bold"
        case .semibold: name = "JetBrainsMono-SemiBold"
        case .medium: name = "JetBrainsMono-Medium"
        default: name = "JetBrainsMono-Regular"
        }
        return .custom(name, size: size)
    }
}

/// Main bank browser view - allows selecting banks and patches
public struct BankBrowserView: View {

    @StateObject private var state = BankBrowserState()
    @Environment(\.dismiss) private var dismiss

    /// Callback fired when a bank/patch is chosen for editing.
    public var onEditTapped: ((Int, Int) -> Void)?

    /// Callback fired by the "Load Bank" toolbar button (128-program dump).
    public var onLoadBankTapped: (() -> Void)?

    /// Callback fired when a full bank is imported from a `.set` / `.syx`.
    public var onBankImported: (([UInt8]) -> Void)?

    /// Callback fired when a single program is imported (e.g. a `.prg` with
    /// no surrounding bank) and the user chooses to open it in the editor.
    public var onProgramImported: ((ProgramFileImport.ImportedProgram) -> Void)?

    /// Callback fired when the user checks specific programs in the import
    /// sheet, picks a destination slot for each, and confirms.
    public var onImportAssignments: (([(program: ProgramFileImport.ImportedProgram, bank: Int, patch: Int)]) -> Void)?

    /// What's currently in a given slot, or nil if empty — lets the import
    /// sheet preview/flag what a chosen destination would overwrite.
    public var occupantName: ((Int, Int) -> String?)?

    /// True once a slot's occupancy is actually known. Always true for
    /// A/B; a C/D slot that's never been individually read also reads
    /// `nil` from `occupantName`, but that's "unknown," not "confirmed
    /// empty" — the import sheet needs this to tell the two apart rather
    /// than treating unread C/D territory as safe to silently fill.
    public var isKnownOccupancy: ((Int, Int) -> Bool)?

    /// Bank dump in progress / its status text, driven by the controller.
    public var isLoadingBank: Bool
    public var bankStatus: String?

    /// The 128 program names from the last bank load (empty until loaded);
    /// cells show these beneath their panel slot labels (A.11...B.88).
    public var programNames: [String]

    /// Optional C/D names — one flat array of 128 strings per extra bank,
    /// keyed by bank number (4 for C, 5 for D). Filled lazily when a C/D
    /// cell is read or loaded as a group (HANDOFF-v10 §2a: C needs 64
    /// individual reads, D is empty from factory).
    public var extraProgramNames: [Int: [String]]

    @State private var showingImportSheet = false
    @State private var droppedFileURL: URL?
    @State private var isDropTargeted = false
    @State private var toastMessage: String?
    @State private var toastIsError = false
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var isConnected = false
    /// The very first resolution can legitimately take upwards of a minute
    /// on a system with many MIDI endpoints — DeviceLocator times out each
    /// non-matching candidate in turn (2.5s apiece) before reaching the
    /// right one, confirmed live: ~25 candidates on this machine before
    /// landing on the actual interface. After that first success,
    /// DeviceLocator's own cache makes every later poll instant. Without
    /// this flag, that first stretch just reads as a confident, wrong
    /// "Not Connected" instead of "still looking."
    @State private var hasResolvedOnce = false

    public init(
        onEditTapped: ((Int, Int) -> Void)? = nil,
        onLoadBankTapped: (() -> Void)? = nil,
        onBankImported: (([UInt8]) -> Void)? = nil,
        onProgramImported: ((ProgramFileImport.ImportedProgram) -> Void)? = nil,
        onImportAssignments: (([(program: ProgramFileImport.ImportedProgram, bank: Int, patch: Int)]) -> Void)? = nil,
        occupantName: ((Int, Int) -> String?)? = nil,
        isKnownOccupancy: ((Int, Int) -> Bool)? = nil,
        isLoadingBank: Bool = false,
        bankStatus: String? = nil,
        programNames: [String] = [],
        extraProgramNames: [Int: [String]] = [:]
    ) {
        self.onEditTapped = onEditTapped
        self.onLoadBankTapped = onLoadBankTapped
        self.onBankImported = onBankImported
        self.onProgramImported = onProgramImported
        self.onImportAssignments = onImportAssignments
        self.occupantName = occupantName
        self.isKnownOccupancy = isKnownOccupancy
        self.isLoadingBank = isLoadingBank
        self.bankStatus = bankStatus
        self.programNames = programNames
        self.extraProgramNames = extraProgramNames
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerView

                Divider()

                bankPatchGridView

                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 1)

                statusBar
            }
            .navigationTitle("MK Patch Librarian")
            .preferredColorScheme(.dark)
            .background(BrowserPalette.deepSpaceBlue)
            .overlay(alignment: .top) { toastBanner }
            // A one-shot check on appear went stale the moment the user
            // plugged the synth back in after it had already reported
            // "Not Connected" — nothing re-ran it. `.task` polls while this
            // screen is actually visible and auto-cancels when it isn't
            // (navigating to the editor), so it's not running in the
            // background when nobody can see the LED anyway.
            .task { await pollConnection() }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 0)
                        .strokeBorder(PatchTheme.accent, lineWidth: 3)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                guard let provider = providers.first else { return false }
                // `loadObject(ofClass: URL.self)` is the documented shortcut
                // but silently fails to call back for plain Finder file
                // drags in practice — `loadItem(forTypeIdentifier:)` against
                // the same UTI, decoding the URL by hand, is the reliable
                // path.
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else {
                        url = item as? URL
                    }
                    DispatchQueue.main.async {
                        guard let url else {
                            showToast("Import failed: couldn't read dropped file\(error.map { " (\($0.localizedDescription))" } ?? "")")
                            return
                        }
                        droppedFileURL = url
                        showingImportSheet = true
                    }
                }
                return true
            }
            .onChange(of: bankStatus) { _, newValue in
                guard let newValue else { return }
                showToast(newValue)
            }
            .sheet(isPresented: $showingImportSheet) {
                ImportProgramsView(
                    onImported: { programs, bank in
                        if let bank {
                            onBankImported?(bank)
                        } else if let first = programs.first {
                            onProgramImported?(first)
                        }
                    },
                    onImportSelected: { assignments in
                        onImportAssignments?(assignments)
                    },
                    occupantName: occupantName,
                    isKnownOccupancy: isKnownOccupancy,
                    onOpenAfterImport: { bank, patch in
                        onEditTapped?(bank, patch)
                    },
                    preloadedURL: droppedFileURL,
                    onDismiss: {
                        showingImportSheet = false
                        droppedFileURL = nil
                    }
                )
                // Forces a fresh ImportProgramsView (new @State, onAppear
                // fires again) per distinct drop — without this, a drop
                // landing while the sheet's identity is still the previous
                // one just mutates preloadedURL on an already-appeared view,
                // which never reloads.
                .id(droppedFileURL)
            }
            .toolbar {
                // Brand mark + title on the leading side, next to the
                // traffic lights — not a button, just identity. The actual
                // window title text stays on `.navigationTitle` below;
                // macOS already left-aligns it next to this once the
                // toolbar has other content, so this just adds the icon.
                ToolbarItem(placement: .navigation) {
                    Text("MK")
                        .font(BrowserFont.inter(12, weight: .heavy))
                        .foregroundColor(BrowserPalette.deepSpaceBlue)
                        .padding(5)
                        .background(Circle().fill(BrowserPalette.icyAqua))
                }

                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 8) {
                        toolbarActionButton(
                            "Import Sound Bank…",
                            // A document icon (vs. Load Bank's piano keys below) so
                            // the two toolbar actions read as distinct at a glance,
                            // not as two near-identical "arrow into a shape" glyphs.
                            icon: "arrow.down.doc",
                            prominent: false
                        ) {
                            showingImportSheet = true
                        }
                        .help("Import .prg / .set / .syx files from disk")

                        toolbarActionButton(
                            "Load from Synth",
                            icon: "pianokeys",
                            prominent: true,
                            isLoading: isLoadingBank,
                            disabled: isLoadingBank
                        ) {
                            onLoadBankTapped?()
                        }
                        .help("Pull all 128 programs from the connected synthesizer")
                    }
                }
            }
        }
    }

    // The generic "Select a patch to edit" instruction is gone per the
    // design brief — the grid itself is self-explanatory. What's left is
    // purely informational: which cell you last opened, so a round trip
    // from the editor doesn't lose your place. Nothing to show at launch,
    // before anything's been opened, so the row collapses to nothing.
    @ViewBuilder
    private var headerView: some View {
        if let bank = state.selectedBank, let patch = state.selectedPatch {
            HStack {
                Spacer()
                Text("Last opened: \(ProgramSlot.anyLabel(bank: bank, patch: patch))")
                    .font(BrowserFont.inter(13, weight: .semibold))
                    .foregroundColor(BrowserPalette.icyAqua)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    /// Icy-aqua for the primary action (Load from Synth — the headline
    /// "sync with hardware" action), dark/secondary for Import (still
    /// icy-aqua text for legibility, just not the filled treatment) — no
    /// stroke/border on either, per the design brief.
    @ViewBuilder
    private func toolbarActionButton(
        _ title: String,
        icon: String,
        prominent: Bool,
        isLoading: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            } else {
                Label(title, systemImage: icon)
                    .labelStyle(.titleAndIcon)
                    .font(BrowserFont.inter(12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(
            disabled ? (prominent ? BrowserPalette.deepSpaceBlue.opacity(0.5) : BrowserPalette.icyAqua.opacity(0.4))
                : prominent ? BrowserPalette.deepSpaceBlue : BrowserPalette.icyAqua
        )
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(prominent ? BrowserPalette.icyAqua.opacity(disabled ? 0.5 : 1) : BrowserPalette.cardBG)
        )
        .disabled(disabled)
        .pointerCursor()
    }

    /// Repeats a MIDI device probe every few seconds for as long as this
    /// view is on screen — driven by `.task`, which cancels this loop
    /// automatically the moment the view disappears (e.g. navigating into
    /// the editor), so it only runs while there's an LED to actually show
    /// it on.
    private func pollConnection() async {
        while !Task.isCancelled {
            await checkConnectionOnce()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
    }

    private func checkConnectionOnce() async {
        await withCheckedContinuation { continuation in
            // Default passes (2), not 1 — findDestination's own doc comment
            // documents a one-off single-pass miss on real hardware (a UM-ONE
            // probe flakiness) that a bare retry reliably fixes. Trimming to
            // 1 pass to keep each poll light also threw away that retry,
            // which is exactly why this kept reporting "Not Connected" with
            // the synth plugged in and working.
            DeviceLocator.findDestination { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success: isConnected = true
                    case .failure: isConnected = false
                    }
                    hasResolvedOnce = true
                    continuation.resume()
                }
            }
        }
    }

    private var bankPatchGridView: some View {
        ThemedScrollView(trackColor: BrowserPalette.deepSpaceBlue, thumbColor: BrowserPalette.blueSlate) {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(0..<ProgramSlot.letterCount, id: \.self) { letter in
                    letterBankGrid(letter: letter)
                }
            }
            .padding()
        }
    }

    /// One letter's full 64-slot block (A, B, C, or D) — 8 groups × 8
    /// digits, read left-to-right top-to-bottom in strict numerical order
    /// (.11, .12, .13...). Replaces the old 4-column grid, whose columns
    /// were actually two half-bank splits each (patchesPerBank=32 per
    /// internal "bank" value, two of which make up one letter) — a row
    /// read A.11, A.51, B.11, B.51, not in sequence. One shape for all
    /// four letters now, A/B included, via the same letter+slot
    /// addressing the import sheet's destination map already uses.
    ///
    /// NON-lazy Grid on purpose: a LazyVGrid with a nested ForEach
    /// materializes only the first row on this macOS (measured —
    /// LazyGridReproTests: nested 2/128, flat 26/128, Grid 128/128). 64
    /// static cells per letter is cheap, so render them all deterministically.
    @ViewBuilder
    private func letterBankGrid(letter: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bank \(ProgramSlot.bankLetter(letter))")
                .font(BrowserFont.inter(13, weight: .semibold))
                .foregroundColor(BrowserPalette.icyAqua)

            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(0..<8, id: \.self) { group in
                    GridRow {
                        ForEach(0..<8, id: \.self) { digit in
                            let slot = group * 8 + digit
                            let resolved = ProgramSlot.resolve(letter: letter, slot: slot)
                            BankBrowserCell(
                                bankNumber: resolved.bank,
                                patchNumber: resolved.patch,
                                programName: occupantName?(resolved.bank, resolved.patch),
                                isSelected: state.selectedBank == resolved.bank && state.selectedPatch == resolved.patch,
                                onEditTapped: {
                                    state.selectedBank = resolved.bank
                                    state.selectedPatch = resolved.patch
                                    onEditTapped?(resolved.bank, resolved.patch)
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    /// Color-coded, auto-dismissing banner for `bankStatus` changes. The
    /// quiet gray status-bar text alone wasn't visible enough — this is the
    /// loud, hard-to-miss version of the same message.
    @ViewBuilder
    private var toastBanner: some View {
        if let toastMessage {
            Text(toastMessage)
                .font(BrowserFont.inter(15, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(toastIsError ? Color.red : Color.green)
                )
                .shadow(radius: 6)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { dismissToast() }
                .pointerCursor()
        }
    }

    private func showToast(_ message: String) {
        toastIsError = message.localizedCaseInsensitiveContains("failed")
            || message.localizedCaseInsensitiveContains("error")
        withAnimation { toastMessage = message }
        toastDismissTask?.cancel()
        toastDismissTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { dismissToast() }
        }
    }

    private func dismissToast() {
        toastDismissTask?.cancel()
        withAnimation { toastMessage = nil }
    }

    // A bare `swift run` binary has no Info.plist, hence the unversioned fallback.
    private static let versionLabel: String = {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "MK Patch Librarian"
        }
        return "MK Patch Librarian v\(version)"
    }()

    // The toast banner owns one-off status messages now; this bar is the
    // branded footer per the design brief — version on the left (replaced
    // by the loading spinner/error when there's something more pressing
    // to say), connection LED on the right.
    private var statusBar: some View {
        HStack(spacing: 16) {
            if isLoadingBank || state.isLoading {
                ProgressView()
                    .scaleEffect(0.8)
            } else if let error = state.error {
                Text(error.localizedDescription)
                    .font(BrowserFont.inter(11))
                    .foregroundColor(.red)
            } else {
                Text(Self.versionLabel)
                    .font(BrowserFont.inter(11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                if !hasResolvedOnce {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Circle()
                        .fill(isConnected ? BrowserPalette.mintLeaf : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                }
                Text(!hasResolvedOnce ? "Checking…" : isConnected ? "Connected to microKORG" : "Not Connected")
                    .font(BrowserFont.inter(11, weight: .medium))
                    .foregroundColor(hasResolvedOnce && isConnected ? BrowserPalette.mintLeaf : .secondary)
            }

            Button(action: {
                print("Show info")
            }) {
                Image(systemName: "info.circle")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// Individual slot cell in the grid: panel label ("A.11"..."B.88") + the
/// program name (from a loaded bank; nil until one is loaded).
private struct BankBrowserCell: View {

    let bankNumber: Int
    let patchNumber: Int
    let programName: String?
    let isSelected: Bool
    let onEditTapped: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onEditTapped) {
            VStack(spacing: 4) {
                Text(ProgramSlot.anyLabel(bank: bankNumber, patch: patchNumber))
                    .font(BrowserFont.mono(16, weight: .bold))
                    .foregroundColor(BrowserPalette.icyAqua)

                Text(programName?.isEmpty == false ? programName! : "—")
                    .font(BrowserFont.inter(12, weight: .medium))
                    .foregroundColor(BrowserPalette.eggshell.opacity(programName?.isEmpty == false ? 1 : 0.4))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    // Hover brightens the card itself, not just the border,
                    // so it reads as tactile — a white wash over cardBG
                    // rather than a second hardcoded color.
                    .fill(BrowserPalette.cardBG)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(isHovering && !isSelected ? 0.04 : 0))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected || isHovering ? BrowserPalette.icyAqua : Color.white.opacity(0.05),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            // Without this, only the text glyphs are tappable — the visible
            // rounded-rect border/fill is just decoration with no hit area
            // of its own, so clicking inside the cell but off the text does
            // nothing even though it looks like one solid button.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
    }
}

#Preview {
    BankBrowserView()
}
