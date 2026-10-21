import SwiftUI
import Models
import PBAPI

/// Main patch editor view - edits a real 254-byte MicroKORG program.
///
/// Every control here reads/writes actual program bytes through
/// `MicroKORGProgram` (offsets from the MIDI Implementation Chart, TABLE 1/2).
/// In Vocoder mode the byte 38+ region switches to the TABLE 3 layout, so the
/// editor swaps in vocoder-specific sections (VocoderProgram accessors);
/// program-common sections (Effects, Arpeggiator) stay in both modes.
public struct EditorView: View {

    @StateObject private var state: EditorState
    @Environment(\.dismiss) private var dismiss
    @State private var showNewProgram = false
    @State private var newProgramName = "New Program"
    @State private var keyboardBaseNote = 60 // middle C
    @State private var heldAuditionNote: Int?
    @State private var isConnectingAudition = false

    /// Current bank/patch being edited
    public let bankNumber: Int
    public let patchNumber: Int

    /// Back navigation — the controller supplies this to return to the bank
    /// browser. Without it the toolbar falls back to `dismiss()`, which closes
    /// the whole window (the editor IS the window's root content).
    public var onBack: (() -> Void)?

    /// Fired after a successful write to the synth, with the exact bytes
    /// just saved. Without this, a save only updated this editor's own
    /// quiet status line — the bank browser grid kept showing the old name
    /// after Back, and no toast fired, because nothing told it a save
    /// happened at all.
    public var onSaved: ((Int, Int, [UInt8]) -> Void)?

    public init(
        bankNumber: Int,
        patchNumber: Int,
        rawData: [UInt8] = [],
        onBack: (() -> Void)? = nil,
        onSaved: ((Int, Int, [UInt8]) -> Void)? = nil
    ) {
        self.bankNumber = bankNumber
        self.patchNumber = patchNumber
        self.onBack = onBack
        self.onSaved = onSaved
        self._state = StateObject(wrappedValue: EditorState(rawData: rawData))
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerView

                Divider()

                ScrollView {
                    // Three columns instead of one long vertical stack of
                    // full-width cards — sections tile across the window's
                    // width the way the hardware panel's own parameter
                    // matrix does, so the goal is the whole patch fitting in
                    // the viewport rather than a tall scroll of oversized
                    // cards. ScrollView stays as a safety net, not the plan.
                    if state.voiceMode == .vocoder {
                        vocoderBanner
                            .padding(.horizontal)
                            .padding(.top, 8)
                    }
                    HStack(alignment: .top, spacing: 6) {
                        VStack(alignment: .leading, spacing: 6) {
                            if state.voiceMode == .vocoder {
                                voiceSection("Vocoder", number: 1) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        VocoderVoiceControls(state: state)
                                        VocoderOscControls(state: state)
                                        VocoderMixerControls(state: state)
                                    }
                                }
                            } else {
                                voiceSection("Voice", number: 1) {
                                    VoiceControls(state: state)
                                }
                                voiceSection("Pitch", number: 2) {
                                    PitchControls(state: state)
                                }
                                voiceSection("OSC 1", number: 3) {
                                    Osc1Controls(state: state)
                                }
                                voiceSection("OSC 2", number: 4) {
                                    Osc2Controls(state: state)
                                }
                                voiceSection("Mixer", number: 5) {
                                    MixerControls(state: state)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)

                        VStack(alignment: .leading, spacing: 6) {
                            if state.voiceMode == .vocoder {
                                voiceSection("Vocoder Filter/Amp", number: 6) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        VocoderFilterControls(state: state)
                                        VocoderAmpControls(state: state)
                                    }
                                }
                                lfoSection("LFO (Vocoder)", number: 10) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        VocoderLFOControls(state: state, lfo: .one)
                                        VocoderLFOControls(state: state, lfo: .two)
                                    }
                                }
                                voiceSection("Vocoder Bands") {
                                    VocoderBandsControls(state: state)
                                }
                            } else {
                                voiceSection("Filter", number: 6) {
                                    FilterControls(state: state)
                                }
                                voiceSection("Filter EG", number: 7) {
                                    FilterEgControls(state: state)
                                }
                                voiceSection("Amp", number: 8) {
                                    AmpControls(state: state)
                                }
                                voiceSection("Amp EG", number: 9) {
                                    AmpEgControls(state: state)
                                }
                                lfoSection("LFO", number: 10) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        LFOControls(state: state, lfo: .one)
                                        LFOControls(state: state, lfo: .two)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)

                        VStack(alignment: .leading, spacing: 6) {
                            if state.voiceMode != .vocoder {
                                voiceSection("Patch", number: 12) {
                                    PatchControls(state: state)
                                }
                            }

                            effectsSection("Effects", number: 16) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ModFXControls(state: state)
                                    DelayFXControls(state: state)
                                }
                            }

                            voiceSection("EQ", number: 18) {
                                EQControls(state: state)
                            }

                            arpSection("Arpeggiator", number: 19) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ArpEnableToggle(state: state)
                                    if state.arpEnabled {
                                        ArpModeSelector(state: state)
                                        ArpRangePicker(state: state)
                                        ArpResolutionPicker(state: state)
                                        ArpGateSlider(state: state)
                                        ArpSwingSlider(state: state)
                                        ArpTempoSlider(state: state)
                                        ArpOptionsControls(state: state)
                                    }
                                    TriggerControls(state: state)
                                }
                            }

                            // Scale (byte 17) is Reserved on the microKORG S —
                            // accessors kept in EditorState, no controls shown.

                            voiceSection("Keyboard") {
                                KbdOctaveControls(state: state)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .padding(8)
                }

                Divider()

                footerView
            }
            .navigationTitle("Edit Patch")
            .preferredColorScheme(.dark)
            .background(PatchTheme.windowBG)
            // Every segmented picker and toggle switch was still rendering
            // in the system default blue, fighting the charcoal/gold theme
            // everywhere. One tint here covers all of them; Save keeps its
            // own explicit .tint(.blue) as the one deliberately different
            // "primary action" color, since that's set locally and wins
            // over this.
            .tint(PatchTheme.accent)
            .onDisappear {
                // Safety net against a stuck note: if a key was still held
                // when this view went away (Back navigation, a dropped
                // gesture), make sure its Note Off actually went out.
                if let heldAuditionNote {
                    stopAuditionNote(heldAuditionNote)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showNewProgram = true }) {
                        Label("New", systemImage: "plus.circle")
                            .labelStyle(.titleAndIcon)
                    }
                    .disabled(state.isBusy)
                    .help("Start a new blank program")
                    .pointerCursor()
                }

                ToolbarItem(placement: .primaryAction) {
                    Button(action: { state.undo() }) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.title2)
                    }
                    .disabled(!state.canUndo || state.isBusy)
                    .keyboardShortcut("z", modifiers: .command)
                    .help("Undo")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button(action: { state.redo() }) {
                        Image(systemName: "arrow.uturn.forward")
                            .font(.title2)
                    }
                    .disabled(!state.canRedo || state.isBusy)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .help("Redo")
                }

                ToolbarItem(placement: .cancellationAction) {
                    Button(action: {
                        if let onBack {
                            onBack()
                        } else {
                            dismiss()
                        }
                    }) {
                        Label("Back to Bank Browser", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("Back to Bank Browser")
                    .pointerCursor()
                }
            }
            .alert("New Program", isPresented: $showNewProgram) {
                TextField("Program name", text: $newProgramName)
                Button("Create", role: .destructive) {
                    state.startNewProgram(name: newProgramName)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Replaces the current buffer with a blank program and clears "
                    + "undo history. Nothing is sent to the synth until you Save.")
            }
        }
    }

    /// Header picker target: T1, T2, or Edit Sync (both at once).
    enum TimbreTarget: Hashable { case one, two, both }

    /// Slot label for the header, Save button, and status line — C/D aware,
    /// so "C.11" never clamps to "B.88".
    private var slotLabel: String {
        ProgramSlot.anyLabel(bank: bankNumber, patch: patchNumber)
    }

    /// Bridges the 3-way picker to `editedTimbre` + `editSync` (both pure UI
    /// state; no bytes, no undo step). Choosing T1/T2 cancels Edit Sync —
    /// same as one TIMBRE SELECT press on the panel.
    private var timbreTarget: Binding<TimbreTarget> {
        Binding(
            get: {
                state.editSync ? .both : (state.editedTimbre == .two ? .two : .one)
            },
            set: { target in
                switch target {
                case .one:
                    state.editedTimbre = .one
                    state.editSync = false
                case .two:
                    state.editedTimbre = .two
                    state.editSync = false
                case .both:
                    state.editedTimbre = .one // display reads T1, per the panel
                    state.editSync = true
                }
            }
        )
    }

    private var headerView: some View {
        HStack(spacing: 12) {
            // Slot badge first and never clipped: `fixedSize` keeps "B.11"
            // whole no matter how wide the pickers get (v15 §3.6).
            Text(slotLabel)
                .font(.headline)
                .monospacedDigit()
                .foregroundColor(PatchTheme.accent)
                .fixedSize()

            Text(state.patchName)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            // The main action on this whole screen, so it sits right next to
            // what you're naming/editing instead of buried in a row of small
            // icon buttons on the far side of the window.
            Button(action: { saveToSynth() }) {
                Label("Save to \(slotLabel)", systemImage: "square.and.arrow.up")
                    .labelStyle(.titleAndIcon)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(state.isBusy)
            .help("Send this program and write it to the shown slot")
            .pointerCursor()
            .hoverHighlight(cornerRadius: 8, activeOpacity: 0.15)

            Spacer()

            // Layer programs hold two complete synth setups; pick which one
            // the per-timbre controls address. Hidden otherwise (Vocoder's
            // 38+ region is the TABLE 3 layout).
            if state.voiceMode == .layer {
                Picker("", selection: timbreTarget) {
                    Text("T1").tag(TimbreTarget.one)
                    Text("T2").tag(TimbreTarget.two)
                    Text("T1+T2").tag(TimbreTarget.both)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                .help("Edit Timbre 1, Timbre 2, or both at once (Edit Sync — like holding TIMBRE SELECT on the synth)")
            }

            // Byte 16: which layout the program uses. Switching to Vocoder
            // swaps the sections below to the TABLE 3 layout; switching to
            // Layer reveals the T1/T2 picker (both timbres sound together).
            Picker("", selection: $state.voiceMode) {
                ForEach(VoiceMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .help("Voice mode: Single, Layer (two timbres), or Vocoder")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var vocoderBanner: some View {
        Label(
            "Vocoder program — sections below use the TABLE 3 layout; Effects & Arpeggiator are program-common.",
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundColor(.blue)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
    }

    private var footerView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Audition")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    if isConnectingAudition {
                        ProgressView().controlSize(.mini)
                        Text("Connecting…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                AuditionKeyboard(
                    baseNote: $keyboardBaseNote,
                    onNoteOn: { playAuditionNote($0) },
                    onNoteOff: { stopAuditionNote($0) }
                )
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if let status = state.status {
                HStack(spacing: 6) {
                    if state.isBusy {
                        ProgressView().controlSize(.mini)
                    }
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 6)
            }

            HStack {
                // Save now lives in the top toolbar, clearly labeled, so
                // there's one unambiguous Save action instead of two
                // differently-styled ones. Load stays here: it's a less
                // common, more consequential action (discards in-progress
                // edits), so it doesn't need equal visual weight.
                Button(action: { loadFromSynth() }) {
                    Label("Reload \(slotLabel) from Synth", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(state.isBusy)
                .help("Discards any unsaved edits here and re-reads \(slotLabel) fresh from the synth's current state")
                .pointerCursor()
                .hoverHighlight()

                Spacer()
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: Hardware actions

    /// Load button: pull the synth's edit buffer via `SysExHandler` and swap
    /// the editor's bytes for what actually came back.
    private func loadFromSynth() {
        state.isBusy = true
        state.status = "Finding synthesizer…"
        DeviceLocator.findDestination { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    state.status = "Load failed: \(error.localizedDescription)"
                    state.isBusy = false
                case .success(let dest):
                    state.status = "Loading from \(dest.name)…"
                    PBAPI.SysExHandler.loadCurrentProgram(deviceID: dest.portRef) { reply in
                        DispatchQueue.main.async {
                            switch reply {
                            case .success(let data):
                                state.load(rawData: data)
                                state.status = "Loaded \"\(state.patchName)\" from synthesizer"
                            case .failure(let error):
                                state.status = "Load failed: \(error.localizedDescription)"
                            }
                            state.isBusy = false
                        }
                    }
                }
            }
        }
    }

    /// The patch's own configured channel, same one Save/Load already talk
    /// to it on. 0xFF ("GLB", no per-timbre channel set) and the "this
    /// timbre doesn't exist in the current voice mode" case both fall back
    /// to channel 1 — a sane default, not a real channel the synth reported.
    private var auditionChannel: Int {
        let raw = state.program.midiChannel(state.editedTimbre)
        guard let raw, raw != 0xFF else { return 0 }
        return Int(raw)
    }

    /// Press: Note On on the patch's own channel. Deliberately doesn't touch
    /// `state.isBusy`/the status line the way Save/Load do — auditioning
    /// shouldn't block the rest of the editor or spam the status on every
    /// key press, only surface a real failure.
    private func playAuditionNote(_ note: Int) {
        if let heldAuditionNote, heldAuditionNote != note {
            stopAuditionNote(heldAuditionNote)
        }
        heldAuditionNote = note
        let channel = auditionChannel

        // Most presses hit DeviceLocator's cache and resolve near-instantly
        // — showing a spinner for those would just flicker and be noisy
        // during normal play. Only show it if resolution is actually slow
        // (cold cache, a retry in flight), by delaying the flag and
        // cancelling it if the real result beats the delay.
        let connectingTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { isConnectingAudition = true }
        }

        DeviceLocator.findDestination { result in
            DispatchQueue.main.async {
                connectingTask.cancel()
                isConnectingAudition = false
                guard case .success(let dest) = result else {
                    state.status = "Audition failed: no synth found"
                    return
                }
                // A prior press can have failed (the UM-ONE probe is known
                // to miss once and work the next try) and left its message
                // sitting here — clear only that stale message, not some
                // unrelated Save/Load status the user might still want to see.
                if state.status?.hasPrefix("Audition failed") == true {
                    state.status = nil
                }
                PBAPI.NoteHandler.noteOn(deviceID: dest.portRef, channel: channel, note: note)
            }
        }
    }

    private func stopAuditionNote(_ note: Int) {
        if heldAuditionNote == note { heldAuditionNote = nil }
        let channel = auditionChannel
        DeviceLocator.findDestination { result in
            DispatchQueue.main.async {
                guard case .success(let dest) = result else { return }
                PBAPI.NoteHandler.noteOff(deviceID: dest.portRef, channel: channel, note: note)
            }
        }
    }

    /// Save button: push the editor's 254 bytes into the edit buffer, then
    /// commit to the browsed slot (ack-gated — a Protect-rejected write
    /// reports failure).
    private func saveToSynth() {
        state.isBusy = true
        state.status = "Finding synthesizer…"
        DeviceLocator.findDestination { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    state.status = "Save failed: \(error.localizedDescription)"
                    state.isBusy = false
                case .success(let dest):
                    state.status = "Sending \(state.patchName)…"
                    if ProgramSlot.isExtraBank(bankNumber) {
                        // C/D: the addressed 0x11 only covers 0...127 (A/B),
                        // so select the slot on the synth first, then send
                        // the program and use an unaddressed 0x11 write.
                        PBAPI.SysExHandler.saveExtraProgram(
                            deviceID: dest.portRef,
                            lsb: ProgramSlot.bankSelectLSB(bank: bankNumber),
                            programChange: ProgramSlot.programChange(bank: bankNumber, patch: patchNumber),
                            data: state.program.data
                        ) { written in
                            DispatchQueue.main.async {
                                switch written {
                                case .success:
                                    state.status = "Saved & written to \(slotLabel)"
                                    onSaved?(bankNumber, patchNumber, state.program.data)
                                case .failure(let error):
                                    state.status = "Save failed: \(error.localizedDescription)"
                                }
                                state.isBusy = false
                            }
                        }
                    } else {
                        PBAPI.SysExHandler.sendCurrentProgram(deviceID: dest.portRef, data: state.program.data) { sent in
                            DispatchQueue.main.async {
                                switch sent {
                                case .failure(let error):
                                    state.status = "Save failed: \(error.localizedDescription)"
                                    state.isBusy = false
                                case .success:
                                    state.status = "Writing to slot…"
                                    // Target the browsed cell explicitly (0x11 pp),
                                    // not whatever slot the front panel selected.
                                    let slot = ProgramSlot.index(bank: bankNumber, patch: patchNumber)
                                    PBAPI.SysExHandler.writeCurrentProgram(
                                        deviceID: dest.portRef,
                                        programIndex: slot
                                    ) { written in
                                        DispatchQueue.main.async {
                                            switch written {
                                            case .success:
                                                state.status = "Saved & written to \(slotLabel)"
                                                onSaved?(bankNumber, patchNumber, state.program.data)
                                            case .failure(let error):
                                                state.status = "Sent, but slot write failed: \(error.localizedDescription)"
                                            }
                                            state.isBusy = false
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// One section = one card. Title bar is deliberately thin — the matrix
    /// cells inside are where the information actually is, so the chrome
    /// around them should cost as little vertical space as possible. The
    /// optional `number` mirrors the microKORG's own EDIT SELECT numbering
    /// (1 VOICE, 2 PITCH, 3-9 OSC1/OSC2/MIXER/FILTER/FILTER EG/AMP/AMP EG,
    /// 10-11 LFO1/2, 12-15 PATCH, 16-18 MOD FX/DELAY/EQ, 19-20 ARPEG A/B —
    /// from the owner's manual's own section list), same spirit as the
    /// hardware panel this is modeled on.
    private func section<Content: View>(_ title: String, number: Int? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let number {
                    Text("\(number)")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(PatchTheme.windowBG)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(PatchTheme.accent))
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(PatchTheme.accent)
                    .textCase(.uppercase)
            }

            content()
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(PatchTheme.cardBG)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(PatchTheme.cardBorder, lineWidth: 1)
        )
    }

    private func voiceSection<Content: View>(_ title: String, number: Int? = nil, @ViewBuilder content: () -> Content) -> some View {
        section(title, number: number, content: content)
    }

    private func effectsSection<Content: View>(_ title: String, number: Int? = nil, @ViewBuilder content: () -> Content) -> some View {
        section(title, number: number, content: content)
    }

    private func lfoSection<Content: View>(_ title: String, number: Int? = nil, @ViewBuilder content: () -> Content) -> some View {
        section(title, number: number, content: content)
    }

    private func arpSection<Content: View>(_ title: String, number: Int? = nil, @ViewBuilder content: () -> Content) -> some View {
        section(title, number: number, content: content)
    }
}

// MARK: - Oscillators (TABLE 2 +7..+14)

// MARK: - Voice (TABLE 2 +1..+2; +0 MIDI ch and +1 B0-2 key priority are
// Reserved on the microKORG S — model accessors kept, no controls shown)

private struct VoiceControls: View {

    @ObservedObject var state: EditorState

    var body: some View {
        var cells: [ControlCell] = [
            pickerCell("Voice Assign", selection: $state.assignMode, options: [
                (tag: UInt8(0), title: "Mono"),
                (tag: UInt8(1), title: "Poly"),
                (tag: UInt8(2), title: "Unison"),
            ], param: "assignMode"),
            pickerCell("Trig Mode", selection: $state.triggerModeMulti, options: [
                (tag: false, title: "Single"),
                (tag: true, title: "Multi"),
            ], param: "triggerModeMulti"),
            toggleCell("FEG Reset", isOn: $state.eg1Reset, param: "eg1Reset"),
            toggleCell("AEG Reset", isOn: $state.eg2Reset, param: "eg2Reset"),
        ]
        if state.assignMode == 2 {
            cells.append(byteSlider("Unison Detune", value: $state.unisonDetune, param: "unisonDetune"))
        }
        return ControlGrid(cells)
    }
}

// MARK: - Pitch (TABLE 2 +3..+6, +15)

private struct PitchControls: View {

    @ObservedObject var state: EditorState

    var body: some View {
        ControlGrid([
            signedSlider("Tune", value: $state.pitchTune, range: -50...50, unit: "¢", param: "pitchTune"),
            signedSlider("Bend Rng", value: $state.bendRange, range: -12...12, unit: "st", param: "bendRange"),
            signedSlider("Transp", value: $state.pitchTranspose, range: -24...24, unit: "st", param: "pitchTranspose"),
            signedSlider("Vibrato Int", value: $state.vibratoIntensity, range: -63...63, param: "vibratoIntensity"),
            byteSlider("Portamento", value: $state.portamento, param: "portamento"),
        ])
    }
}

// MARK: - Osc 1 (TABLE 2 +7..+10)

private struct Osc1Controls: View {

    @ObservedObject var state: EditorState

    /// *T-2 DWGS wave names are on the synth's display; show DWGS No. 1...64.
    var body: some View {
        var cells: [ControlCell] = [
            pickerCell("Wave", selection: $state.osc1Wave,
                       options: Osc1Wave.allCases.map { (tag: $0, title: $0.label) },
                       param: "osc1Wave"),
            byteSlider("Wave Ctrl 1", value: $state.osc1Control1, param: "osc1Control1"),
            byteSlider("Wave Ctrl 2", value: $state.osc1Control2, param: "osc1Control2"),
        ]
        if state.osc1Wave == .dwgs {
            // 0...63 = DWGS No. 1...64; only sent when the wave is DWGS.
            cells.append(pickerCell("DWGS Wave", selection: $state.dwgsWave,
                                    options: (0...63).map { (tag: $0, title: "No. \($0 + 1)") },
                                    param: "dwgsWave"))
        }
        return ControlGrid(cells)
    }
}

// MARK: - Osc 2 (TABLE 2 +12..+14)

private struct Osc2Controls: View {

    @ObservedObject var state: EditorState

    var body: some View {
        ControlGrid([
            pickerCell("Wave", selection: $state.osc2Wave,
                       options: Osc2Wave.allCases.map { (tag: $0, title: $0.label) },
                       param: "osc2Wave"),
            pickerCell("Mod", selection: $state.osc2Mod,
                       options: Osc2Mod.allCases.map { (tag: $0, title: $0.label) },
                       param: "osc2Mod"),
            signedSlider("Semitone", value: $state.osc2Semitone, range: -24...24, unit: "st", param: "osc2Semitone"),
            signedSlider("Tune", value: $state.osc2Tune, range: -63...63, param: "osc2Tune"),
        ])
    }
}

// MARK: - Mixer (TABLE 2 +16..+18)

private struct MixerControls: View {

    @ObservedObject var state: EditorState

    var body: some View {
        ControlGrid([
            byteSlider("Osc 1 Level", value: $state.osc1Level, param: "osc1Level"),
            byteSlider("Osc 2 Level", value: $state.osc2Level, param: "osc2Level"),
            byteSlider("Noise Level", value: $state.noiseLevel, param: "noiseLevel"),
        ])
    }
}

// MARK: - Filter (TABLE 2 +19..+24)

private struct FilterControls: View {

    @ObservedObject var state: EditorState

    var body: some View {
        ControlGrid([
            pickerCell("Type", selection: $state.filterType,
                       options: FilterType.allCases.map { (tag: $0, title: $0.label) },
                       param: "filterType"),
            byteSlider("Cutoff", value: $state.filterCutoff, param: "filterCutoff"),
            byteSlider("Resonance", value: $state.filterResonance, param: "filterResonance"),
            signedSlider("Filter EG Int", value: $state.filterEG1Intensity, range: -63...63, param: "filterEG1Intensity"),
            // +23 Velocity Sense is Reserved on the microKORG S — accessor kept, no control.
            signedSlider("Kbd Track", value: $state.filterKeyboardTrack, range: -63...63, param: "filterKeyboardTrack"),
        ])
    }
}

// MARK: - Filter EG (TABLE 2 +30..+33)

private struct FilterEgControls: View {

    @ObservedObject var state: EditorState

    var body: some View {
        ControlGrid([
            ControlCell(wide: true, content: AnyView(
                ADSRCurveView(attack: state.eg1Attack, decay: state.eg1Decay,
                              sustain: state.eg1Sustain, release: state.eg1Release)
                    .tooltip("The filter envelope's shape, drawn from the four sliders below.")
            )),
            byteSlider("Attack", value: $state.eg1Attack, param: "eg1Attack"),
            byteSlider("Decay", value: $state.eg1Decay, param: "eg1Decay"),
            byteSlider("Sustain", value: $state.eg1Sustain, param: "eg1Sustain"),
            byteSlider("Release", value: $state.eg1Release, param: "eg1Release"),
        ])
    }
}

// MARK: - Amp EG (TABLE 2 +34..+37)

private struct AmpEgControls: View {

    @ObservedObject var state: EditorState

    var body: some View {
        ControlGrid([
            ControlCell(wide: true, content: AnyView(
                ADSRCurveView(attack: state.eg2Attack, decay: state.eg2Decay,
                              sustain: state.eg2Sustain, release: state.eg2Release)
                    .tooltip("The amp envelope's shape, drawn from the four sliders below.")
            )),
            byteSlider("Attack", value: $state.eg2Attack, param: "eg2Attack"),
            byteSlider("Decay", value: $state.eg2Decay, param: "eg2Decay"),
            byteSlider("Sustain", value: $state.eg2Sustain, param: "eg2Sustain"),
            byteSlider("Release", value: $state.eg2Release, param: "eg2Release"),
        ])
    }
}

// MARK: - Amp (TABLE 2 +25..+29)

private struct AmpControls: View {

    @ObservedObject var state: EditorState

    var body: some View {
        ControlGrid([
            byteSlider("Level", value: $state.ampLevel, param: "ampLevel"),
            byteSlider("Panpot", value: $state.panpot, param: "panpot", readout: Readout.panpot),
            toggleCell("Distort", isOn: $state.ampDistortion, param: "ampDistortion"),
            // +28 Velocity Sense is Reserved on the microKORG S — accessor kept, no control.
            signedSlider("Kbd Track", value: $state.ampKeyboardTrack, range: -63...63, param: "ampKeyboardTrack"),
        ])
    }
}

// MARK: - Patch 1..4 (TABLE 2 +44..+51)

private struct PatchControls: View {

    @ObservedObject var state: EditorState

    var body: some View {
        ControlGrid((0..<4).map { patchCell($0) })
    }

    /// Each patch routing reads as one connected block — Source → Destination
    /// on its own line, Intensity below — instead of three separately-
    /// labeled matrix cells. One field per line, each its own
    /// label-left/control-right row, is the shape every other cell in this
    /// editor already uses, and that's what makes it fit: a `wide: true`
    /// cell gets no `cellWidth` frame from `ControlGrid` (by design, so
    /// e.g. segmented pickers can span a full row), so its Picker sized to
    /// its *ideal* width — a menu Picker's minimum is set by its longest
    /// possible option ("Osc2 Pitch"), not whatever's selected — with
    /// nothing forcing it to compress. With no outer constraint, SwiftUI
    /// just grants that ideal width, pushing the control's rendered
    /// position past the column, past the window edge, into the region a
    /// vertical ScrollView clips by default — invisible, not truncated.
    /// This cell is one column wide now (not a full row), so it needs the
    /// same explicit `cellWidth` frame every normal cell gets — `wide:
    /// false` — which is what actually forces the Picker to compress and
    /// render inside the visible card, the same way it already works for
    /// every other Picker-bearing cell in this editor (VOICE ASSIGN,
    /// FILTER TYPE, etc).
    private func patchCell(_ index: Int) -> ControlCell {
        ControlCell(wide: false, content: AnyView(
            VStack(alignment: .leading, spacing: 3) {
                Text("Patch \(index + 1)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(PatchTheme.dustGrey.opacity(0.8))

                patchField("SRC") {
                    Picker("", selection: sourceBinding(index)) {
                        ForEach(PatchSource.allCases, id: \.self) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                }

                patchField("DEST") {
                    Picker("", selection: destinationBinding(index)) {
                        ForEach(PatchDestination.allCases, id: \.self) { destination in
                            Text(destination.label).tag(destination)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                }

                patchField("INT") {
                    ScrubField(
                        text: Readout.signed(intensityBinding(index).wrappedValue, range: -63...63),
                        sensitivity: 3
                    ) { delta in
                        let binding = intensityBinding(index)
                        binding.wrappedValue = max(-63, min(63, binding.wrappedValue + delta))
                    }
                }
            }
            .matrixBox()
        ))
    }

    @ViewBuilder
    private func patchField<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(PatchTheme.dustGrey.opacity(0.8))
                .textCase(.uppercase)
            Spacer(minLength: 2)
            value()
        }
    }

    private func sourceBinding(_ index: Int) -> Binding<PatchSource> {
        switch index {
        case 0: return $state.patch1Source
        case 1: return $state.patch2Source
        case 2: return $state.patch3Source
        default: return $state.patch4Source
        }
    }

    private func destinationBinding(_ index: Int) -> Binding<PatchDestination> {
        switch index {
        case 0: return $state.patch1Destination
        case 1: return $state.patch2Destination
        case 2: return $state.patch3Destination
        default: return $state.patch4Destination
        }
    }

    private func intensityBinding(_ index: Int) -> Binding<Int> {
        switch index {
        case 0: return $state.patch1Intensity
        case 1: return $state.patch2Intensity
        case 2: return $state.patch3Intensity
        default: return $state.patch4Intensity
        }
    }
}

// MARK: - EQ (TABLE 1 bytes 26..29)

private struct EQControls: View {

    @ObservedObject var state: EditorState

    /// *T-10: 0...29 = 1.00...18.0 kHz.
    private static let hiFreqLabels: [String] = [
        "1.00", "1.25", "1.50", "1.75", "2.00",
        "2.25", "2.50", "2.75", "3.00", "3.25",
        "3.50", "3.75", "4.00", "4.25", "4.50",
        "4.75", "5.00", "5.25", "5.50", "5.75",
        "6.00", "7.00", "8.00", "9.00", "10.0",
        "11.0", "12.0", "14.0", "16.0", "18.0",
    ]

    /// *T-11: 0...29 = 40...1000 Hz.
    private static let lowFreqLabels: [String] = [
        "40", "50", "60", "80", "100",
        "120", "140", "160", "180", "200",
        "220", "240", "260", "280", "300",
        "320", "340", "360", "380", "400",
        "420", "440", "460", "480", "500",
        "600", "700", "800", "900", "1000",
    ]

    var body: some View {
        ControlGrid([
            pickerCell("Hi Freq", selection: $state.eqHiFreq,
                       options: Self.hiFreqLabels.enumerated().map { (tag: $0.offset, title: $0.element) },
                       valueText: "\(Self.hiFreqLabels[state.eqHiFreq]) kHz",
                       param: "eqHiFreq"),
            signedSlider("High Gain", value: $state.eqHiGain, range: -12...12, param: "eqHiGain"),
            pickerCell("Lo Freq", selection: $state.eqLowFreq,
                       options: Self.lowFreqLabels.enumerated().map { (tag: $0.offset, title: $0.element) },
                       valueText: "\(Self.lowFreqLabels[state.eqLowFreq]) Hz",
                       param: "eqLowFreq"),
            signedSlider("Low Gain", value: $state.eqLowGain, range: -12...12, param: "eqLowGain"),
        ])
    }
}

// MARK: - Scale (TABLE 1 byte 17) — Reserved on the microKORG S; the
// ScaleControls view was removed. EditorState.scaleKey/scaleType accessors
// stay so the byte round-trips untouched (values preserved on load/save).

// MARK: - KBD Octave (TABLE 1 byte 37)

private struct KbdOctaveControls: View {

    @ObservedObject var state: EditorState

    var body: some View {
        ControlGrid([
            signedSlider("KBD Octave", value: $state.kbdOctave, range: -3...3, unit: "oct", param: "kbdOctave"),
        ])
    }
}

// MARK: - Mod FX / Delay FX (TABLE 1 bytes 19..25)

private struct ModFXControls: View {

    @ObservedObject var state: EditorState

    var body: some View {
        ControlGrid([
            headerCell("Mod FX"),
            pickerCell("Type", selection: $state.modFxType,
                       options: ModFxType.allCases.map { (tag: $0, title: $0.label) },
                       param: "modFxType"),
            byteSlider("LFO Speed", value: $state.modFxSpeed, param: "modFxSpeed"),
            byteSlider("Depth", value: $state.modFxDepth, param: "modFxDepth"),
        ])
    }
}

private struct DelayFXControls: View {

    @ObservedObject var state: EditorState

    var body: some View {
        var cells: [ControlCell] = [
            headerCell("Delay FX"),
            toggleCell("Tmp Sync", isOn: $state.delaySync, param: "delaySync"),
            pickerCell("Type", selection: $state.delayType,
                       options: DelayType.allCases.map { (tag: $0, title: $0.label) },
                       param: "delayType"),
        ]
        if state.delaySync {
            // *T-1: 0..14 = 1/32 .. 1/1
            cells.append(pickerCell("Time Base", selection: $state.delayTimeBase,
                                    options: Self.timeBaseLabels.enumerated().map { (tag: $0.offset, title: $0.element) },
                                    param: "delayTimeBase"))
        } else {
            cells.append(byteSlider("Delay Time", value: $state.delayTime, param: "delayTime"))
        }
        cells.append(byteSlider("Depth", value: $state.delayDepth, param: "delayDepth"))
        return ControlGrid(cells)
    }

    private static let timeBaseLabels = [
        "1/32", "1/24", "1/16", "1/12", "3/32",
        "1/8", "1/6", "3/16", "1/4", "1/3",
        "3/8", "1/2", "2/3", "3/4", "1/1",
    ]
}

// MARK: - LFOs (TABLE 2 +38..+43)

private enum LFOSelector { case one, two }

private struct LFOControls: View {

    @ObservedObject var state: EditorState
    let lfo: LFOSelector

    /// *T-5: 0...14 = 1/1 ... 1/32.
    private static let syncLabels = [
        "1/1", "3/4", "2/3", "1/2", "3/8",
        "1/3", "1/4", "3/16", "1/6", "1/8",
        "3/32", "1/12", "1/16", "1/24", "1/32",
    ]

    var body: some View {
        var cells: [ControlCell] = [headerCell(lfo == .one ? "LFO 1" : "LFO 2")]
        if lfo == .one {
            cells.append(contentsOf: [
                pickerCell("Wave", selection: $state.lfo1Wave,
                           options: LFO1Wave.allCases.map { (tag: $0, title: $0.label) },
                           param: "lfo1Wave"),
                byteSlider("Frequency", value: $state.lfo1Frequency, param: "lfo1Frequency"),
                toggleCell("Tmp Sync", isOn: $state.lfo1TempoSync, param: "lfo1TempoSync"),
            ])
            if state.lfo1TempoSync {
                cells.append(pickerCell("Sync Note", selection: $state.lfo1SyncNote,
                                        options: Self.syncLabels.enumerated().map { (tag: $0.offset, title: $0.element) },
                                        param: "lfo1SyncNote"))
            }
            cells.append(pickerCell("Key Sync", selection: $state.lfo1KeySync, options: [
                (tag: 0, title: "Off"),
                (tag: 1, title: "Timbre"),
                (tag: 2, title: "Voice"),
            ], param: "lfo1KeySync"))
        } else {
            cells.append(contentsOf: [
                pickerCell("Wave", selection: $state.lfo2Wave,
                           options: LFO2Wave.allCases.map { (tag: $0, title: $0.label) },
                           param: "lfo2Wave"),
                byteSlider("Frequency", value: $state.lfo2Frequency, param: "lfo2Frequency"),
                toggleCell("Tmp Sync", isOn: $state.lfo2TempoSync, param: "lfo2TempoSync"),
            ])
            if state.lfo2TempoSync {
                cells.append(pickerCell("Sync Note", selection: $state.lfo2SyncNote,
                                        options: Self.syncLabels.enumerated().map { (tag: $0.offset, title: $0.element) },
                                        param: "lfo2SyncNote"))
            }
            cells.append(pickerCell("Key Sync", selection: $state.lfo2KeySync, options: [
                (tag: 0, title: "Off"),
                (tag: 1, title: "Timbre"),
                (tag: 2, title: "Voice"),
            ], param: "lfo2KeySync"))
        }
        return ControlGrid(cells)
    }
}

// MARK: - Arpeggiator (TABLE 1 bytes 32..36)

private struct ArpEnableToggle: View {

    @ObservedObject var state: EditorState

    var body: some View {
        ControlGrid([
            toggleCell("Arpeggiator", isOn: $state.arpEnabled, param: "arpEnabled"),
        ])
    }
}

private struct ArpModeSelector: View {

    @ObservedObject var state: EditorState

    var body: some View {
        ControlGrid([
            pickerCell("Type", selection: $state.arpType,
                       options: ArpType.allCases.map { (tag: $0, title: $0.label) },
                       param: "arpType"),
        ])
    }
}

private struct ArpRangePicker: View {

    @ObservedObject var state: EditorState

    /// Stored 0..3, displayed 1..4 octaves.
    private var rangeBinding: Binding<Int> {
        Binding(
            get: { state.arpRange + 1 },
            set: { state.arpRange = $0 - 1 }
        )
    }

    var body: some View {
        ControlGrid([
            pickerCell("Octave Range", selection: rangeBinding,
                       options: (1...4).map { (tag: $0, title: "\($0) oct") },
                       param: "arpRange"),
        ])
    }
}

private struct ArpGateSlider: View {

    @ObservedObject var state: EditorState

    var body: some View {
        ControlGrid([
            byteSlider("Gate", value: $state.arpGate, param: "arpGate",
                       readout: { Readout.unsigned($0, unit: "%") }),
        ])
    }
}

private struct ArpSwingSlider: View {

    @ObservedObject var state: EditorState

    var body: some View {
        ControlGrid([
            signedSlider("Swing", value: $state.arpSwing, range: -100...100, param: "arpSwing"),
        ])
    }
}

/// 0...5 = 1/24, 1/16, 1/12, 1/8, 1/6, 1/4 (byte 35).
private struct ArpResolutionPicker: View {

    @ObservedObject var state: EditorState

    private static let labels = ["1/24", "1/16", "1/12", "1/8", "1/6", "1/4"]

    var body: some View {
        ControlGrid([
            pickerCell("Resolution", selection: $state.arpResolution,
                       options: Self.labels.enumerated().map { (tag: $0.offset, title: $0.element) },
                       param: "arpResolution"),
        ])
    }
}

/// 16-bit tempo, 20...300 BPM (bytes 30/31).
private struct ArpTempoSlider: View {

    @ObservedObject var state: EditorState

    var body: some View {
        ControlGrid([
            ControlCell(content: AnyView(
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Tempo")
                            .font(.caption)
                        Spacer()
                        Text("\(state.arpTempo) BPM")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { Double(state.arpTempo) },
                            set: { state.arpTempo = Int($0.rounded()) }
                        ),
                        in: 20...300,
                        step: 1
                    )
                }
                .tooltip(EditorHelp.text(param: "arpTempo", inline: nil))
            )),
        ])
    }
}

/// Latch / Target / Key Sync (byte 32).
private struct ArpOptionsControls: View {

    @ObservedObject var state: EditorState

    var body: some View {
        ControlGrid([
            toggleCell("Latch", isOn: $state.arpLatch, param: "arpLatch"),
            pickerCell("Target", selection: $state.arpTarget, options: [
                (tag: UInt8(0), title: "Both"),
                (tag: UInt8(1), title: "Timbre 1"),
                (tag: UInt8(2), title: "Timbre 2"),
            ], param: "arpTarget"),
            toggleCell("Key Sync", isOn: $state.arpKeySync, param: "arpKeySync"),
        ])
    }
}

/// Trigger control (bytes 14/15) — arp-adjacent per the chart.
private struct TriggerControls: View {

    @ObservedObject var state: EditorState

    /// Bit `step` of byte 15, 1 = On.
    private func stepBinding(_ step: Int) -> Binding<Bool> {
        Binding(
            get: { (state.triggerPattern >> UInt8(step)) & 1 == 1 },
            set: {
                let bit = UInt8(1 << step)
                state.triggerPattern = $0
                    ? state.triggerPattern | bit
                    : state.triggerPattern & ~bit
            }
        )
    }

    var body: some View {
        ControlGrid([
            ControlCell(wide: true, content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("Trigger")
                        .font(.subheadline)

                    Picker("Length", selection: $state.triggerLength) {
                        ForEach(0...7, id: \.self) { value in
                            Text("\(value + 1) step\(value == 0 ? "" : "s")").tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120, alignment: .leading)
                    .tooltip(EditorHelp.text(param: "triggerLength", inline: nil))

                    Text("Pattern")
                        .font(.caption)
                    // Plain HStack, not a lazy container (Lazy renders one row here).
                    HStack(spacing: 8) {
                        ForEach(0..<8, id: \.self) { step in
                            Toggle("S\(step + 1)", isOn: stepBinding(step))
                                .toggleStyle(.checkbox)
                                .font(.caption)
                        }
                    }
                    .tooltip(EditorHelp.text(param: "triggerPattern", inline: nil))
                }
            )),
        ])
    }
}

// MARK: - Vocoder (TABLE 3, relative offsets from byte 38)

private enum VocoderLFOSelector { case one, two }

private struct VocoderVoiceControls: View {

    @ObservedObject var state: EditorState

    var body: some View {
        ControlGrid([
            headerCell("Voice"),

            // TABLE 3 +0 MIDI ch is Reserved on the microKORG S — accessor
            // kept (vocoderMidiChannel), no control shown.

            pickerCell("Assign", selection: $state.vocoderAssignMode, options: [
                (tag: UInt8(0), title: "Mono"),
                (tag: UInt8(1), title: "Poly"),
                (tag: UInt8(2), title: "Unison"),
            ], help: "Mono = one note at a time, Poly = normal, Unison = all voices stacked on one note."),
            byteSlider("Unison Detune", value: $state.vocoderUnisonDetune,
                       help: "How far apart the stacked unison voices are pitched."),
            signedSlider("Tune", value: $state.vocoderTune, range: -50...50, unit: "¢",
                         help: "Fine-tunes the carrier oscillators in cents."),
            signedSlider("Bend Rng", value: $state.vocoderBendRange, range: -12...12, unit: "st",
                         help: "How many semitones the pitch wheel bends at full throw."),
            signedSlider("Transp", value: $state.vocoderTranspose, range: -24...24, unit: "st",
                         help: "Moves the whole sound up or down in semitones."),
            signedSlider("Vibrato", value: $state.vocoderVibratoIntensity, range: -63...63,
                         help: "How deep the vibrato gets when the MOD wheel is pushed all the way."),
            byteSlider("Portamento", value: $state.vocoderPortamento,
                       help: "Glide speed between notes; 0 is off."),
        ])
    }
}

private struct VocoderOscControls: View {

    @ObservedObject var state: EditorState

    var body: some View {
        var cells: [ControlCell] = [
            headerCell("Oscillator"),
            pickerCell("Wave", selection: $state.vocoderOscWave,
                       options: Osc1Wave.allCases.map { (tag: $0, title: $0.label) },
                       help: "The carrier's waveform — the raw material of the vocoder sound."),
            byteSlider("Control 1", value: $state.vocoderOscControl1,
                       help: "Shapes the selected wave (pulse width on Pulse, saw morph on Saw)."),
            byteSlider("Control 2", value: $state.vocoderOscControl2,
                       help: "How much LFO 1 wobbles what Control 1 shaped."),
        ]
        if state.vocoderOscWave == .dwgs {
            cells.append(byteSlider("DWGS Wave", value: $state.vocoderDwgsWave,
                                    help: "Which of the 64 DWGS waveforms the carrier plays.",
                                    readout: { "No. \($0 + 1)" }))
        }
        return ControlGrid(cells)
    }
}

/// Audio-in / envelope-follower + the mixer levels (TABLE 3 +12, +14..+20).
private struct VocoderMixerControls: View {

    @ObservedObject var state: EditorState

    var body: some View {
        ControlGrid([
            headerCell("Audio In / Mixer"),
            toggleCell("HPF Gate", isOn: $state.vocoderHpfGate,
                       help: "Pass the input's high frequencies only while keys are held (on), or always (off)."),
            byteSlider("HPF Level", value: $state.vocoderHpfLevel,
                       help: "How much of the input's high frequencies (consonants) blend into the sound."),
            byteSlider("Gate Sense", value: $state.vocoderGateSense,
                       help: "Adjust so the vocoder sound is not cut off unnaturally."),
            byteSlider("Threshold", value: $state.vocoderThreshold,
                       help: "Input level below which the mic is silenced — raise it to kill background noise."),

            byteSlider("Osc Level", value: $state.vocoderOscLevel,
                       help: "How loud the carrier oscillator is fed into the vocoder bands."),
            byteSlider("Ext (Synth) Level", value: $state.vocoderExtLevel,
                       help: "How loud the AUDIO IN 2 signal is used as the carrier."),
            byteSlider("Noise Level", value: $state.vocoderNoiseLevel,
                       help: "How much noise is mixed into the carrier."),
        ])
    }
}

private struct VocoderFilterControls: View {

    @ObservedObject var state: EditorState

    var body: some View {
        var cells: [ControlCell] = [
            headerCell("Filter"),
            pickerCell("Shift", selection: $state.vocoderFilterShift,
                       options: VocoderFilterShift.allCases.map { (tag: $0, title: $0.label) },
                       help: "Shifts every band's frequency up or down by whole filter steps (Formant Shift)."),
            signedSlider("Cutoff", value: $state.vocoderFilterCutoff, range: -63...63,
                         help: "Continuously shifts every band's frequency — the vocoder's brightness."),
            byteSlider("Resonance", value: $state.vocoderFilterResonance,
                       help: "Emphasizes each band's frequency — more vocal, more ring."),
            pickerCell("Mod Source", selection: $state.vocoderFilterModSource,
                       options: VocoderFilterModSource.allCases.map { (tag: $0, title: $0.label) },
                       help: "What sweeps the bands: an envelope or an LFO."),
            signedSlider("Intensity", value: $state.vocoderFilterIntensity, range: -63...63,
                         help: "How far the chosen source sweeps the bands."),
            byteSlider("E.F. Sense", value: $state.vocoderEfSense,
                       help: "How strongly the voice's loudness shapes the vocoder's attack and release."),
        ]
        if state.vocoderEfSense == 127 {
            cells.append(noteCell("127 = Hold — the E.F. Hold levels below are used instead."))
        }
        return ControlGrid(cells)
    }
}

private struct VocoderAmpControls: View {

    @ObservedObject var state: EditorState

    var body: some View {
        ControlGrid([
            headerCell("Amp"),
            byteSlider("Amp Level", value: $state.vocoderAmpLevel,
                       help: "The vocoder's output volume."),
            byteSlider("Direct Level", value: $state.vocoderDirectLevel,
                       help: "How much of the raw input sound passes straight through."),
            toggleCell("Distort", isOn: $state.vocoderDistortion,
                       help: "Adds drive to the vocoder's sound."),
            signedSlider("Velocity Sense", value: $state.vocoderVelSense, range: -64...63,
                         help: "How strongly playing strength affects the sound."),
            signedSlider("Kbd Track", value: $state.vocoderKeyTrack, range: -63...63,
                         help: "Makes high notes louder (+) or quieter (−)."),

            headerCell("EG 2 (Amp)"),
            byteSlider("Attack", value: $state.vocoderEg2Attack,
                       help: "How long the sound takes to fade in after a key press."),
            byteSlider("Decay", value: $state.vocoderEg2Decay,
                       help: "How long the volume takes to settle from its peak to the sustain level."),
            byteSlider("Sustain", value: $state.vocoderEg2Sustain,
                       help: "How loud the sound stays while the key is held."),
            byteSlider("Release", value: $state.vocoderEg2Release,
                       help: "How long the sound rings out after the key is released."),
        ])
    }
}

private struct VocoderLFOControls: View {

    @ObservedObject var state: EditorState
    let lfo: VocoderLFOSelector

    /// *T-5: 0...14 = 1/1 ... 1/32.
    private static let syncLabels = [
        "1/1", "3/4", "2/3", "1/2", "3/8",
        "1/3", "1/4", "3/16", "1/6", "1/8",
        "3/32", "1/12", "1/16", "1/24", "1/32",
    ]

    var body: some View {
        var cells: [ControlCell] = [headerCell(lfo == .one ? "LFO 1" : "LFO 2")]
        if lfo == .one {
            cells.append(contentsOf: [
                pickerCell("Wave", selection: $state.vocoderLfo1Wave,
                           options: LFO1Wave.allCases.map { (tag: $0, title: $0.label) },
                           help: "LFO 1's shape: Saw, Squ, Tri, or S/H (random steps)."),
                byteSlider("Frequency", value: $state.vocoderLfo1Frequency,
                           help: "How fast LFO 1 moves."),
                toggleCell("Tmp Sync", isOn: $state.vocoderLfo1TempoSync,
                           help: "Lock LFO 1's speed to the song's tempo note values."),
            ])
            if state.vocoderLfo1TempoSync {
                cells.append(pickerCell("Sync Note", selection: $state.vocoderLfo1SyncNote,
                                        options: Self.syncLabels.enumerated().map { (tag: UInt8($0.offset), title: $0.element) },
                                        help: "The note value LFO 1 cycles in, when Tempo Sync is on."))
            }
        } else {
            cells.append(contentsOf: [
                pickerCell("Wave", selection: $state.vocoderLfo2Wave,
                           options: LFO2Wave.allCases.map { (tag: $0, title: $0.label) },
                           help: "LFO 2's shape: Saw, Squ(+), Sin, or S/H (random steps)."),
                byteSlider("Frequency", value: $state.vocoderLfo2Frequency,
                           help: "How fast LFO 2 moves."),
                toggleCell("Tmp Sync", isOn: $state.vocoderLfo2TempoSync,
                           help: "Lock LFO 2's speed to the song's tempo note values."),
            ])
            if state.vocoderLfo2TempoSync {
                cells.append(pickerCell("Sync Note", selection: $state.vocoderLfo2SyncNote,
                                        options: Self.syncLabels.enumerated().map { (tag: UInt8($0.offset), title: $0.element) },
                                        help: "The note value LFO 2 cycles in, when Tempo Sync is on."))
            }
        }
        return ControlGrid(cells)
    }
}

/// 8 band level/pan pairs + the 16 E.F. Hold levels (TABLE 4, collapsed).
private struct VocoderBandsControls: View {

    @ObservedObject var state: EditorState
    @State private var showHoldLevels = false

    private func bandLevelBinding(_ band: Int) -> Binding<UInt8> {
        Binding(
            get: { state.vocoderBandLevels[band] },
            set: {
                var levels = state.vocoderBandLevels
                levels[band] = $0
                state.vocoderBandLevels = levels
            }
        )
    }

    private func bandPanBinding(_ band: Int) -> Binding<UInt8> {
        Binding(
            get: { state.vocoderBandPans[band] },
            set: {
                var pans = state.vocoderBandPans
                pans[band] = $0
                state.vocoderBandPans = pans
            }
        )
    }

    private func holdBinding(_ channel: Int) -> Binding<Double> {
        Binding(
            get: { Double(state.vocoderEfHoldLevels[channel]) },
            set: {
                var levels = state.vocoderEfHoldLevels
                levels[channel] = Int($0.rounded())
                state.vocoderEfHoldLevels = levels
            }
        )
    }

    var body: some View {
        var cells: [ControlCell] = []
        for band in 0..<MicroKORGProgram.vocoderBandCount {
            cells.append(byteSlider("Band \(band + 1) Level", value: bandLevelBinding(band),
                                    help: "How loud this frequency band is."))
            cells.append(byteSlider("Band \(band + 1) Pan", value: bandPanBinding(band),
                                    help: "Where this band sits between left and right."))
        }

        cells.append(ControlCell(wide: true, content: AnyView(efHoldDisclosure)))
        return ControlGrid(cells)
    }

    private var efHoldDisclosure: some View {
        DisclosureGroup("E.F. Hold Levels (16 channels)", isExpanded: $showHoldLevels) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Used when E.F. Sense = Hold. 24-bit values; the low byte is always 00h.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ForEach(0..<MicroKORGProgram.vocoderChannelCount, id: \.self) { channel in
                    HStack {
                        Text("CH \(channel + 1)")
                            .font(.caption)
                            .frame(width: 48, alignment: .leading)
                        Slider(value: holdBinding(channel),
                               in: 0...Double(0x7FFFFF),
                               step: 1)
                        Text(String(format: "0x%06X", state.vocoderEfHoldLevels[channel]))
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Editor State

/// Observable wrapper over a real 254-byte program buffer.
///
/// Each property is a computed view onto `MicroKORGProgram` bytes; setting one
/// mutates the buffer and republishes, so the next SysEx write sends exactly
/// what the user sees. Timbre-scoped properties address `editedTimbre`.
final class EditorState: ObservableObject {

    @Published private(set) var program: MicroKORGProgram

    /// Last Load/Save result, surfaced in the footer.
    @Published var status: String?
    /// True while a SysEx exchange is in flight (buttons disable, spinner shows).
    @Published var isBusy: Bool = false

    init(rawData: [UInt8] = []) {
        if let program = MicroKORGProgram(data: rawData) {
            self.program = program
        } else if let program = try? MicroKORGProgram.fromSysEx(rawData) {
            self.program = program
        } else {
            self.program = .blank()
        }
    }

    /// Replace the buffer with freshly loaded bytes (Load button / bank load).
    /// Unrecognized input keeps the current buffer rather than blanking it.
    /// Loading *different* content is a document switch: undo history clears.
    func load(rawData: [UInt8]) {
        let before = program
        restore(rawData)
        if program != before {
            clearHistory()
        }
        objectWillChange.send()
    }

    // MARK: Undo / redo (snapshot-based)

    /// Pre-change 254-byte snapshots, most recent last. Every editor control
    /// funnels through `mutate`, so snapshotting there covers all of them.
    private(set) var undoStack: [[UInt8]] = []
    /// Snapshots undone but not yet redone; any new edit clears them.
    private(set) var redoStack: [[UInt8]] = []
    /// Changes closer together than this merge into ONE undo step, so a
    /// slider drag undoes as a single gesture. Tests set 0 (record every
    /// change) or a large value (merge a whole scripted burst).
    var undoCoalesceWindow: TimeInterval = 0.75
    private var lastEditTime = Date.distantPast
    /// True while an undo/redo snapshot is being applied — never recorded.
    private var isRestoring = false

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private static let undoLimit = 100

    /// Step back one recorded edit/burst. Pushes the current state to the
    /// redo stack.
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(program.data)
        applySnapshot(previous)
    }

    /// Re-apply the most recently undone state.
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(program.data)
        applySnapshot(next)
    }

    /// Drop all history (document switch: Load of new content, New Program).
    func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        lastEditTime = .distantPast
    }

    /// Replace the buffer with a blank program named `name` (New Program
    /// dialog). Nothing is sent to the synth; Save does that explicitly.
    func startNewProgram(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var fresh = MicroKORGProgram.blank()
        fresh.setName(trimmed.isEmpty ? "Init" : trimmed)
        objectWillChange.send()
        program = fresh
        clearHistory()
        status = "New program \"\(patchName)\" — not sent to the synth yet"
    }

    /// Accept 254 raw bytes or a complete SysEx message; silently keeps the
    /// current buffer for anything else.
    private func restore(_ bytes: [UInt8]) {
        if let program = MicroKORGProgram(data: bytes) {
            self.program = program
        } else if let program = try? MicroKORGProgram.fromSysEx(bytes) {
            self.program = program
        }
    }

    private func applySnapshot(_ bytes: [UInt8]) {
        isRestoring = true
        restore(bytes)
        isRestoring = false
        lastEditTime = .distantPast // a new edit after undo records again
        objectWillChange.send()
    }

    /// Which timbre the per-timbre controls read and write. UI state, not a
    /// program change: set it directly, never through `mutate { }` — it
    /// touches no bytes and records no undo step (v13 §3.1).
    @Published var editedTimbre: MicroKORGProgram.Timbre = .one

    /// Edit Sync (v15 §4.0) — the hardware's hold-TIMBRE-SELECT-2 s mode:
    /// per-timbre edits apply to BOTH timbres at once; the display shows
    /// T1's values (docs/microkorg-s-panel-facts.md, p.14: Edit Sync is NOT
    /// saved with the program). UI state like `editedTimbre`: set directly,
    /// never through `mutate { }`, never in undo history. Reads always
    /// address `editedTimbre` (T1 while syncing); only writes double.
    @Published var editSync: Bool = false

    /// Apply a per-timbre byte change to every write-target timbre in ONE
    /// undoable mutation: both timbres under Edit Sync, else the edited one.
    /// All per-timbre setters funnel through this.
    func mutateTimbre(_ change: (MicroKORGProgram.Timbre) -> Void) {
        let targets: [MicroKORGProgram.Timbre] = editSync ? [.one, .two] : [editedTimbre]
        mutate {
            for timbre in targets {
                change(timbre)
            }
        }
    }

    private func mutate(_ change: () -> Void) {
        let before = program.data
        objectWillChange.send()
        change()
        guard !isRestoring, program.data != before else { return }
        recordUndo(before)
    }

    /// Push the pre-change snapshot — but only at the start of a burst, so a
    /// continuous slider drag collapses into one undo step.
    private func recordUndo(_ before: [UInt8]) {
        let now = Date()
        guard now.timeIntervalSince(lastEditTime) >= undoCoalesceWindow else {
            return // same gesture as the previous change; pre-state is stored
        }
        undoStack.append(before)
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
        redoStack.removeAll()
        lastEditTime = now
    }

    // Program level
    var patchName: String {
        get { program.name }
        set { mutate { program.setName(newValue) } }
    }

    /// Byte 16 B4-5. Writable: switching mode re-arranges the editor (the
    /// 38+ region becomes TABLE 3 in Vocoder mode). Leaving Layer returns
    /// the controls to Timbre 1 — a hidden picker must not keep editing
    /// bytes the synth ignores in Single mode.
    var voiceMode: VoiceMode {
        get { program.voiceMode }
        set {
            mutate { program.setVoiceMode(newValue) }
            if newValue != .layer {
                // UI state only — no bytes, no undo step.
                editedTimbre = .one
                editSync = false
            }
        }
    }

    // Oscillators
    var osc1Wave: Osc1Wave {
        get { program.osc1Wave(editedTimbre) ?? .saw }
        set { mutateTimbre { program.setOsc1Wave(newValue, $0) } }
    }

    var osc2Wave: Osc2Wave {
        get { program.osc2Wave(editedTimbre) ?? .saw }
        set { mutateTimbre { program.setOsc2Wave(newValue, $0) } }
    }

    var osc2Mod: Osc2Mod {
        get { program.osc2Mod(editedTimbre) ?? .off }
        set { mutateTimbre { program.setOsc2Mod(newValue, $0) } }
    }

    var osc2Semitone: Int {
        get { program.osc2Semitone(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setOsc2Semitone(newValue, $0) } }
    }

    // Mixer (+16..+18)
    var osc1Level: UInt8 {
        get { program.osc1Level(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setOsc1Level(newValue, $0) } }
    }

    var osc2Level: UInt8 {
        get { program.osc2Level(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setOsc2Level(newValue, $0) } }
    }

    var noiseLevel: UInt8 {
        get { program.noiseLevel(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setNoiseLevel(newValue, $0) } }
    }

    // Filter
    var filterType: FilterType {
        get { program.filterType(editedTimbre) ?? .lp24 }
        set { mutateTimbre { program.setFilterType(newValue, $0) } }
    }

    var filterCutoff: UInt8 {
        get { program.filterCutoff(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setFilterCutoff(newValue, $0) } }
    }

    var filterResonance: UInt8 {
        get { program.filterResonance(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setFilterResonance(newValue, $0) } }
    }

    var filterEG1Intensity: Int {
        get { program.filterEG1Intensity(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setFilterEG1Intensity(newValue, $0) } }
    }

    // AMP (+25..+29)
    var ampLevel: UInt8 {
        get { program.ampLevel(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setAmpLevel(newValue, $0) } }
    }

    var panpot: UInt8 {
        get { program.panpot(editedTimbre) ?? 64 }
        set { mutateTimbre { program.setPanpot(newValue, $0) } }
    }

    var ampDistortion: Bool {
        get { program.distortion(editedTimbre) ?? false }
        set { mutateTimbre { program.setDistortion(newValue, $0) } }
    }

    var ampVelocitySense: Int {
        get { program.ampVelocitySense(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setAmpVelocitySense(newValue, $0) } }
    }

    var ampKeyboardTrack: Int {
        get { program.ampKeyboardTrack(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setAmpKeyboardTrack(newValue, $0) } }
    }

    // EG1 = filter envelope
    var eg1Attack: UInt8 {
        get { program.eg1Attack(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setEg1Attack(newValue, $0) } }
    }

    var eg1Decay: UInt8 {
        get { program.eg1Decay(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setEg1Decay(newValue, $0) } }
    }

    var eg1Sustain: UInt8 {
        get { program.eg1Sustain(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setEg1Sustain(newValue, $0) } }
    }

    var eg1Release: UInt8 {
        get { program.eg1Release(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setEg1Release(newValue, $0) } }
    }

    // EG2 = amp envelope
    var eg2Attack: UInt8 {
        get { program.eg2Attack(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setEg2Attack(newValue, $0) } }
    }

    var eg2Decay: UInt8 {
        get { program.eg2Decay(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setEg2Decay(newValue, $0) } }
    }

    var eg2Sustain: UInt8 {
        get { program.eg2Sustain(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setEg2Sustain(newValue, $0) } }
    }

    var eg2Release: UInt8 {
        get { program.eg2Release(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setEg2Release(newValue, $0) } }
    }

    // Mod FX
    var modFxType: ModFxType {
        get { program.modFxType }
        set { mutate { program.setModFxType(newValue) } }
    }

    var modFxSpeed: UInt8 {
        get { program.modFxSpeed }
        set { mutate { program.setModFxSpeed(newValue) } }
    }

    var modFxDepth: UInt8 {
        get { program.modFxDepth }
        set { mutate { program.setModFxDepth(newValue) } }
    }

    // Delay FX
    var delaySync: Bool {
        get { program.delaySync }
        set { mutate { program.setDelaySync(newValue) } }
    }

    var delayTime: UInt8 {
        get { program.delayTime }
        set { mutate { program.setDelayTime(newValue) } }
    }

    var delayTimeBase: Int {
        get { Int(program.delayTimeBase) }
        set { mutate { program.setDelayTimeBase(UInt8(newValue)) } }
    }

    var delayDepth: UInt8 {
        get { program.delayDepth }
        set { mutate { program.setDelayDepth(newValue) } }
    }

    var delayType: DelayType {
        get { program.delayType }
        set { mutate { program.setDelayType(newValue) } }
    }

    // LFO 1
    var lfo1Wave: LFO1Wave {
        get { program.lfo1Wave(editedTimbre) ?? .saw }
        set { mutateTimbre { program.setLfo1Wave(newValue, $0) } }
    }

    var lfo1Frequency: UInt8 {
        get { program.lfo1Frequency(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setLfo1Frequency(newValue, $0) } }
    }

    var lfo1TempoSync: Bool {
        get { program.lfo1TempoSync(editedTimbre) ?? false }
        set { mutateTimbre { program.setLfo1TempoSync(newValue, $0) } }
    }

    // LFO 2
    var lfo2Wave: LFO2Wave {
        get { program.lfo2Wave(editedTimbre) ?? .saw }
        set { mutateTimbre { program.setLfo2Wave(newValue, $0) } }
    }

    var lfo2Frequency: UInt8 {
        get { program.lfo2Frequency(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setLfo2Frequency(newValue, $0) } }
    }

    var lfo2TempoSync: Bool {
        get { program.lfo2TempoSync(editedTimbre) ?? false }
        set { mutateTimbre { program.setLfo2TempoSync(newValue, $0) } }
    }

    // Arpeggiator
    var arpEnabled: Bool {
        get { program.arpEnabled }
        set { mutate { program.setArpEnabled(newValue) } }
    }

    var arpType: ArpType {
        get { program.arpType }
        set { mutate { program.setArpType(newValue) } }
    }

    /// Stored 0..3 (1..4 octaves).
    var arpRange: Int {
        get { Int(program.arpRange) }
        set { mutate { program.setArpRange(UInt8(newValue)) } }
    }

    var arpGate: UInt8 {
        get { program.arpGate }
        set { mutate { program.setArpGate(newValue) } }
    }

    var arpSwing: Int {
        get { program.arpSwing }
        set { mutate { program.setArpSwing(newValue) } }
    }

    var arpLatch: Bool {
        get { program.arpLatch }
        set { mutate { program.setArpLatch(newValue) } }
    }

    /// 0=Both, 1=Timbre1, 2=Timbre2.
    var arpTarget: UInt8 {
        get { program.arpTarget }
        set { mutate { program.setArpTarget(newValue) } }
    }

    var arpKeySync: Bool {
        get { program.arpKeySync }
        set { mutate { program.setArpKeySync(newValue) } }
    }

    /// 0..5 = 1/24, 1/16, 1/12, 1/8, 1/6, 1/4.
    var arpResolution: Int {
        get { Int(program.arpResolution) }
        set { mutate { program.setArpResolution(UInt8(newValue)) } }
    }

    /// 20..300 BPM (16-bit big-endian at bytes 30/31).
    var arpTempo: Int {
        get { program.arpTempo }
        set { mutate { program.setArpTempo(newValue) } }
    }

    /// 0..7 = 1..8 steps (byte 14, B0~2).
    var triggerLength: Int {
        get { Int(program.triggerLength) }
        set { mutate { program.setTriggerLength(UInt8(newValue)) } }
    }

    /// B0~7 = 1st..8th step, true = On (byte 15).
    var triggerPattern: UInt8 {
        get { program.triggerPattern }
        set { mutate { program.setTriggerPattern(newValue) } }
    }

    // Scale (byte 17)
    /// 0 = C ... 11 = B.
    var scaleKey: Int {
        get { Int(program.scaleKey) }
        set { mutate { program.setScaleKey(UInt8(newValue)) } }
    }

    /// 0..9 = Equal Temp .. User (Korg MS2000-family order).
    var scaleType: Int {
        get { Int(program.scaleType) }
        set { mutate { program.setScaleType(UInt8(newValue)) } }
    }

    // EQ (bytes 26..29)
    var eqHiFreq: Int {
        get { Int(program.eqHiFreq) }
        set { mutate { program.setEqHiFreq(UInt8(newValue)) } }
    }

    var eqHiGain: Int {
        get { program.eqHiGain }
        set { mutate { program.setEqHiGain(newValue) } }
    }

    var eqLowFreq: Int {
        get { Int(program.eqLowFreq) }
        set { mutate { program.setEqLowFreq(UInt8(newValue)) } }
    }

    var eqLowGain: Int {
        get { program.eqLowGain }
        set { mutate { program.setEqLowGain(newValue) } }
    }

    // KBD Octave (byte 37), -3..+3.
    var kbdOctave: Int {
        get { program.kbdOctave }
        set { mutate { program.setKbdOctave(newValue) } }
    }

    // MARK: Voice (TABLE 2 +0..+2) — same defaults as the vocoder controls.

    /// 0xFF = GLB, 0...15 = MIDI channels 1...16.
    var midiChannel: UInt8 {
        get { program.midiChannel(editedTimbre) ?? 255 }
        set { mutateTimbre { program.setMidiChannel(newValue, $0) } }
    }

    /// 0=Mono, 1=Poly, 2=Unison.
    var assignMode: UInt8 {
        get { program.assignMode(editedTimbre) ?? 1 }
        set { mutateTimbre { program.setAssignMode(newValue, $0) } }
    }

    var eg1Reset: Bool {
        get { program.eg1Reset(editedTimbre) ?? false }
        set { mutateTimbre { program.setEg1Reset(newValue, $0) } }
    }

    var eg2Reset: Bool {
        get { program.eg2Reset(editedTimbre) ?? false }
        set { mutateTimbre { program.setEg2Reset(newValue, $0) } }
    }

    /// false = Single, true = Multi (Mono/Unison modes).
    var triggerModeMulti: Bool {
        get { program.triggerMode(editedTimbre) ?? false }
        set { mutateTimbre { program.setTriggerMode(newValue, $0) } }
    }

    /// 0=Last, 1=Low, 2=High.
    var keyPriority: Int {
        get { Int(program.keyPriority(editedTimbre) ?? 0) }
        set { mutateTimbre { program.setKeyPriority(UInt8(newValue), $0) } }
    }

    var unisonDetune: UInt8 {
        get { program.unisonDetune(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setUnisonDetune(newValue, $0) } }
    }

    // MARK: Pitch (TABLE 2 +3..+6, +15)

    var pitchTune: Int {
        get { program.tune(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setTune(newValue, $0) } }
    }

    var bendRange: Int {
        get { program.bendRange(editedTimbre) ?? 12 }
        set { mutateTimbre { program.setBendRange(newValue, $0) } }
    }

    var pitchTranspose: Int {
        get { program.transpose(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setTranspose(newValue, $0) } }
    }

    var vibratoIntensity: Int {
        get { program.vibratoIntensity(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setVibratoIntensity(newValue, $0) } }
    }

    var portamento: UInt8 {
        get { program.portamento(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setPortamento(newValue, $0) } }
    }

    // MARK: Oscillator extras (TABLE 2 +8, +9, +10, +14)

    var osc1Control1: UInt8 {
        get { program.osc1Control1(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setOsc1Control1(newValue, $0) } }
    }

    var osc1Control2: UInt8 {
        get { program.osc1Control2(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setOsc1Control2(newValue, $0) } }
    }

    /// 0..63 = DWGS No. 1...64; only meaningful when Osc 1 Wave == DWGS.
    var dwgsWave: Int {
        get { Int(program.dwgsWave(editedTimbre) ?? 0) }
        set { mutateTimbre { program.setDwgsWave(UInt8(newValue), $0) } }
    }

    var osc2Tune: Int {
        get { program.osc2Tune(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setOsc2Tune(newValue, $0) } }
    }

    // MARK: Filter extras (TABLE 2 +23, +24)

    var filterVelocitySense: Int {
        get { program.filterVelocitySense(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setFilterVelocitySense(newValue, $0) } }
    }

    var filterKeyboardTrack: Int {
        get { program.filterKeyboardTrack(editedTimbre) ?? 0 }
        set { mutateTimbre { program.setFilterKeyboardTrack(newValue, $0) } }
    }

    // MARK: LFO sync/key sync (TABLE 2 +38/+40, +41/+43)

    var lfo1SyncNote: Int {
        get { Int(program.lfo1SyncNote(editedTimbre) ?? 0) }
        set { mutateTimbre { program.setLfo1SyncNote(UInt8(newValue), $0) } }
    }

    var lfo1KeySync: Int {
        get { Int(program.lfo1KeySync(editedTimbre) ?? 0) }
        set { mutateTimbre { program.setLfo1KeySync(UInt8(newValue), $0) } }
    }

    var lfo2SyncNote: Int {
        get { Int(program.lfo2SyncNote(editedTimbre) ?? 0) }
        set { mutateTimbre { program.setLfo2SyncNote(UInt8(newValue), $0) } }
    }

    var lfo2KeySync: Int {
        get { Int(program.lfo2KeySync(editedTimbre) ?? 0) }
        set { mutateTimbre { program.setLfo2KeySync(UInt8(newValue), $0) } }
    }

    // MARK: Patch 1..4 (TABLE 2 +44..+51) — concrete vars so every binding
    // is addressable by key path for the §3e byte-coverage registry.

    var patch1Source: PatchSource {
        get { program.patchSource(0, editedTimbre) ?? .eg1 }
        set { mutateTimbre { program.setPatchSource(0, newValue, $0) } }
    }
    var patch1Destination: PatchDestination {
        get { program.patchDestination(0, editedTimbre) ?? .pitch }
        set { mutateTimbre { program.setPatchDestination(0, newValue, $0) } }
    }
    var patch1Intensity: Int {
        get { program.patchIntensity(0, editedTimbre) ?? 0 }
        set { mutateTimbre { program.setPatchIntensity(0, newValue, $0) } }
    }

    var patch2Source: PatchSource {
        get { program.patchSource(1, editedTimbre) ?? .eg1 }
        set { mutateTimbre { program.setPatchSource(1, newValue, $0) } }
    }
    var patch2Destination: PatchDestination {
        get { program.patchDestination(1, editedTimbre) ?? .pitch }
        set { mutateTimbre { program.setPatchDestination(1, newValue, $0) } }
    }
    var patch2Intensity: Int {
        get { program.patchIntensity(1, editedTimbre) ?? 0 }
        set { mutateTimbre { program.setPatchIntensity(1, newValue, $0) } }
    }

    var patch3Source: PatchSource {
        get { program.patchSource(2, editedTimbre) ?? .eg1 }
        set { mutateTimbre { program.setPatchSource(2, newValue, $0) } }
    }
    var patch3Destination: PatchDestination {
        get { program.patchDestination(2, editedTimbre) ?? .pitch }
        set { mutateTimbre { program.setPatchDestination(2, newValue, $0) } }
    }
    var patch3Intensity: Int {
        get { program.patchIntensity(2, editedTimbre) ?? 0 }
        set { mutateTimbre { program.setPatchIntensity(2, newValue, $0) } }
    }

    var patch4Source: PatchSource {
        get { program.patchSource(3, editedTimbre) ?? .eg1 }
        set { mutateTimbre { program.setPatchSource(3, newValue, $0) } }
    }
    var patch4Destination: PatchDestination {
        get { program.patchDestination(3, editedTimbre) ?? .pitch }
        set { mutateTimbre { program.setPatchDestination(3, newValue, $0) } }
    }
    var patch4Intensity: Int {
        get { program.patchIntensity(3, editedTimbre) ?? 0 }
        set { mutateTimbre { program.setPatchIntensity(3, newValue, $0) } }
    }

    // MARK: Vocoder (TABLE 3) — accessors are non-nil only in Vocoder mode;
    // neutral fallbacks here just keep the pickers well-formed.

    // Voice (+0..+6, +14)
    var vocoderMidiChannel: UInt8 {
        get { program.vocoderMidiChannel() ?? 255 }
        set { mutate { program.setVocoderMidiChannel(newValue) } }
    }

    var vocoderAssignMode: UInt8 {
        get { program.vocoderAssignMode() ?? 1 }
        set { mutate { program.setVocoderAssignMode(newValue) } }
    }

    var vocoderUnisonDetune: UInt8 {
        get { program.vocoderUnisonDetune() ?? 0 }
        set { mutate { program.setVocoderUnisonDetune(newValue) } }
    }

    var vocoderTune: Int {
        get { program.vocoderTune() ?? 0 }
        set { mutate { program.setVocoderTune(newValue) } }
    }

    var vocoderBendRange: Int {
        get { program.vocoderBendRange() ?? 2 }
        set { mutate { program.setVocoderBendRange(newValue) } }
    }

    var vocoderTranspose: Int {
        get { program.vocoderTranspose() ?? 0 }
        set { mutate { program.setVocoderTranspose(newValue) } }
    }

    var vocoderVibratoIntensity: Int {
        get { program.vocoderVibratoIntensity() ?? 0 }
        set { mutate { program.setVocoderVibratoIntensity(newValue) } }
    }

    var vocoderPortamento: UInt8 {
        get { program.vocoderPortamento() ?? 0 }
        set { mutate { program.setVocoderPortamento(newValue) } }
    }

    // Oscillator (+7..+10)
    var vocoderOscWave: Osc1Wave {
        get { program.vocoderOscWave() ?? .saw }
        set { mutate { program.setVocoderOscWave(newValue) } }
    }

    var vocoderOscControl1: UInt8 {
        get { program.vocoderOscControl1() ?? 0 }
        set { mutate { program.setVocoderOscControl1(newValue) } }
    }

    var vocoderOscControl2: UInt8 {
        get { program.vocoderOscControl2() ?? 0 }
        set { mutate { program.setVocoderOscControl2(newValue) } }
    }

    var vocoderDwgsWave: UInt8 {
        get { program.vocoderDwgsWave() ?? 0 }
        set { mutate { program.setVocoderDwgsWave(newValue) } }
    }

    // Audio in / mixer (+12, +15..+20)
    var vocoderHpfGate: Bool {
        get { program.vocoderHpfGate() ?? false }
        set { mutate { program.setVocoderHpfGate(newValue) } }
    }

    var vocoderHpfLevel: UInt8 {
        get { program.vocoderHpfLevel() ?? 0 }
        set { mutate { program.setVocoderHpfLevel(newValue) } }
    }

    var vocoderGateSense: UInt8 {
        get { program.vocoderGateSense() ?? 0 }
        set { mutate { program.setVocoderGateSense(newValue) } }
    }

    var vocoderThreshold: UInt8 {
        get { program.vocoderThreshold() ?? 0 }
        set { mutate { program.setVocoderThreshold(newValue) } }
    }

    var vocoderOscLevel: UInt8 {
        get { program.vocoderOscLevel() ?? 0 }
        set { mutate { program.setVocoderOscLevel(newValue) } }
    }

    var vocoderExtLevel: UInt8 {
        get { program.vocoderExtLevel() ?? 0 }
        set { mutate { program.setVocoderExtLevel(newValue) } }
    }

    var vocoderNoiseLevel: UInt8 {
        get { program.vocoderNoiseLevel() ?? 0 }
        set { mutate { program.setVocoderNoiseLevel(newValue) } }
    }

    // Filter (+21..+26)
    var vocoderFilterShift: VocoderFilterShift {
        get { program.vocoderFilterShift() ?? .zero }
        set { mutate { program.setVocoderFilterShift(newValue) } }
    }

    var vocoderFilterCutoff: Int {
        get { program.vocoderFilterCutoff() ?? 0 }
        set { mutate { program.setVocoderFilterCutoff(newValue) } }
    }

    var vocoderFilterResonance: UInt8 {
        get { program.vocoderFilterResonance() ?? 0 }
        set { mutate { program.setVocoderFilterResonance(newValue) } }
    }

    var vocoderFilterModSource: VocoderFilterModSource {
        get { program.vocoderFilterModSource() ?? .dash }
        set { mutate { program.setVocoderFilterModSource(newValue) } }
    }

    var vocoderFilterIntensity: Int {
        get { program.vocoderFilterIntensity() ?? 0 }
        set { mutate { program.setVocoderFilterIntensity(newValue) } }
    }

    var vocoderEfSense: UInt8 {
        get { program.vocoderEfSense() ?? 0 }
        set { mutate { program.setVocoderEfSense(newValue) } }
    }

    // Amp (+27..+31, EG2 +36..+39)
    var vocoderAmpLevel: UInt8 {
        get { program.vocoderAmpLevel() ?? 0 }
        set { mutate { program.setVocoderAmpLevel(newValue) } }
    }

    var vocoderDirectLevel: UInt8 {
        get { program.vocoderDirectLevel() ?? 0 }
        set { mutate { program.setVocoderDirectLevel(newValue) } }
    }

    var vocoderDistortion: Bool {
        get { program.vocoderDistortion() ?? false }
        set { mutate { program.setVocoderDistortion(newValue) } }
    }

    var vocoderVelSense: Int {
        get { program.vocoderVelSense() ?? 0 }
        set { mutate { program.setVocoderVelSense(newValue) } }
    }

    var vocoderKeyTrack: Int {
        get { program.vocoderKeyTrack() ?? 0 }
        set { mutate { program.setVocoderKeyTrack(newValue) } }
    }

    var vocoderEg2Attack: UInt8 {
        get { program.vocoderEg2Attack() ?? 0 }
        set { mutate { program.setVocoderEg2Attack(newValue) } }
    }

    var vocoderEg2Decay: UInt8 {
        get { program.vocoderEg2Decay() ?? 0 }
        set { mutate { program.setVocoderEg2Decay(newValue) } }
    }

    var vocoderEg2Sustain: UInt8 {
        get { program.vocoderEg2Sustain() ?? 0 }
        set { mutate { program.setVocoderEg2Sustain(newValue) } }
    }

    var vocoderEg2Release: UInt8 {
        get { program.vocoderEg2Release() ?? 0 }
        set { mutate { program.setVocoderEg2Release(newValue) } }
    }

    // LFOs (+40..+45)
    var vocoderLfo1Wave: LFO1Wave {
        get { program.vocoderLfo1Wave() ?? .saw }
        set { mutate { program.setVocoderLfo1Wave(newValue) } }
    }

    var vocoderLfo1Frequency: UInt8 {
        get { program.vocoderLfo1Frequency() ?? 0 }
        set { mutate { program.setVocoderLfo1Frequency(newValue) } }
    }

    var vocoderLfo1TempoSync: Bool {
        get { program.vocoderLfo1TempoSync() ?? false }
        set { mutate { program.setVocoderLfo1TempoSync(newValue) } }
    }

    var vocoderLfo1SyncNote: UInt8 {
        get { program.vocoderLfo1SyncNote() ?? 0 }
        set { mutate { program.setVocoderLfo1SyncNote(newValue) } }
    }

    var vocoderLfo2Wave: LFO2Wave {
        get { program.vocoderLfo2Wave() ?? .saw }
        set { mutate { program.setVocoderLfo2Wave(newValue) } }
    }

    var vocoderLfo2Frequency: UInt8 {
        get { program.vocoderLfo2Frequency() ?? 0 }
        set { mutate { program.setVocoderLfo2Frequency(newValue) } }
    }

    var vocoderLfo2TempoSync: Bool {
        get { program.vocoderLfo2TempoSync() ?? false }
        set { mutate { program.setVocoderLfo2TempoSync(newValue) } }
    }

    var vocoderLfo2SyncNote: UInt8 {
        get { program.vocoderLfo2SyncNote() ?? 0 }
        set { mutate { program.setVocoderLfo2SyncNote(newValue) } }
    }

    // Bands (+46..+77) and E.F. Hold (+78..+141) as fixed-size arrays.
    var vocoderBandLevels: [UInt8] {
        get { (0..<MicroKORGProgram.vocoderBandCount).map { program.vocoderBandLevel($0) ?? 0 } }
        set {
            mutate {
                for (band, value) in newValue.enumerated()
                where band < MicroKORGProgram.vocoderBandCount {
                    program.setVocoderBandLevel(value, band)
                }
            }
        }
    }

    var vocoderBandPans: [UInt8] {
        get { (0..<MicroKORGProgram.vocoderBandCount).map { program.vocoderBandPan($0) ?? 0 } }
        set {
            mutate {
                for (band, value) in newValue.enumerated()
                where band < MicroKORGProgram.vocoderBandCount {
                    program.setVocoderBandPan(value, band)
                }
            }
        }
    }

    var vocoderEfHoldLevels: [Int] {
        get { (0..<MicroKORGProgram.vocoderChannelCount).map { program.vocoderEfHoldLevel($0) ?? 0 } }
        set {
            mutate {
                for (channel, value) in newValue.enumerated()
                where channel < MicroKORGProgram.vocoderChannelCount {
                    program.setVocoderEfHoldLevel(value, channel)
                }
            }
        }
    }
}

// MARK: - §3e byte-coverage registry

/// Every non-dummy chart byte mapped to the `EditorState` property that edits
/// it. `EditorByteCoverageTests` walks TABLE 1 (bytes 0..37) and TABLE 2 in
/// BOTH halves (+0..+51 at base 38 → 38..89, and at base 146 → 146..197) and
/// fails on any drift — this registry IS the "literal copy of all the params"
/// contract. Dummy bytes (12, 13, 18, +11, and +52..107 past the walk range in
/// each half) must never appear. TABLE 2 entries are marked `scope: .timbre`;
/// the walk demands their chart offsets be covered in both bases, so a future
/// timbre-2 param cannot be forgotten (v13 §3.3).
///
/// Primary reference: the microKORG S MIDI chart (rev 1.01, 2026) at
/// `docs/microkorg-s-midi-implementation-2026.txt`. The original microKORG
/// chart (rev 1.4) documents params the S marks `(Reserved)`; those entries
/// keep their model accessors (bytes round-trip untouched on load/save) but
/// show no UI control — flagged `reservedOnS` here so the walk still
/// accounts for every byte.
enum EditorByteCoverage {

    /// Where an entry's bytes live. `.timbre` entries address the edited
    /// timbre's TABLE 2 block (base 38 or 146); the byte-coverage walk
    /// requires them to be accounted for in BOTH halves (v13 §3.3).
    enum Scope {
        case program
        case timbre
    }

    struct Entry {
        /// Absolute offsets in the 254-byte buffer this binding writes
        /// (Timbre 1 addresses; `.timbre` entries cover the same chart
        /// offsets at base 146 too).
        let bytes: [Int]
        let name: String
        let path: PartialKeyPath<EditorState>
        /// False only for params whose EditorState binding is read-only
        /// (none currently — voice mode became writable in v13 §4.1).
        let writable: Bool
        /// True when the S chart marks the byte `(Reserved)` — the accessor
        /// exists and preserves the loaded value, but no control is shown.
        let reservedOnS: Bool
        /// Whether the binding edits program-level (TABLE 1) or per-timbre
        /// (TABLE 2) bytes.
        let scope: Scope

        init(bytes: [Int], name: String, path: PartialKeyPath<EditorState>,
             writable: Bool, reservedOnS: Bool = false,
             scope: Scope = .program) {
            self.bytes = bytes
            self.name = name
            self.path = path
            self.writable = writable
            self.reservedOnS = reservedOnS
            self.scope = scope
        }
    }

    static let entries: [Entry] = {
        let t1 = 38 // Timbre 1 base; Timbre 2 (base 146) is covered via scope
        var list: [Entry] = [
            // TABLE 1 — program level
            Entry(bytes: Array(0...11), name: "name", path: \.patchName, writable: true),
            Entry(bytes: [14], name: "triggerLength", path: \.triggerLength, writable: true),
            Entry(bytes: [15], name: "triggerPattern", path: \.triggerPattern, writable: true),
            Entry(bytes: [16], name: "voiceMode", path: \.voiceMode, writable: true),
            Entry(bytes: [17], name: "scaleKey", path: \.scaleKey, writable: true, reservedOnS: true),
            Entry(bytes: [17], name: "scaleType", path: \.scaleType, writable: true, reservedOnS: true),
            Entry(bytes: [19], name: "delaySync", path: \.delaySync, writable: true),
            Entry(bytes: [19], name: "delayTimeBase", path: \.delayTimeBase, writable: true),
            Entry(bytes: [20], name: "delayTime", path: \.delayTime, writable: true),
            Entry(bytes: [21], name: "delayDepth", path: \.delayDepth, writable: true),
            Entry(bytes: [22], name: "delayType", path: \.delayType, writable: true),
            Entry(bytes: [23], name: "modFxSpeed", path: \.modFxSpeed, writable: true),
            Entry(bytes: [24], name: "modFxDepth", path: \.modFxDepth, writable: true),
            Entry(bytes: [25], name: "modFxType", path: \.modFxType, writable: true),
            Entry(bytes: [26], name: "eqHiFreq", path: \.eqHiFreq, writable: true),
            Entry(bytes: [27], name: "eqHiGain", path: \.eqHiGain, writable: true),
            Entry(bytes: [28], name: "eqLowFreq", path: \.eqLowFreq, writable: true),
            Entry(bytes: [29], name: "eqLowGain", path: \.eqLowGain, writable: true),
            Entry(bytes: [30, 31], name: "arpTempo", path: \.arpTempo, writable: true),
            Entry(bytes: [32], name: "arpEnabled", path: \.arpEnabled, writable: true),
            Entry(bytes: [32], name: "arpLatch", path: \.arpLatch, writable: true),
            Entry(bytes: [32], name: "arpTarget", path: \.arpTarget, writable: true),
            Entry(bytes: [32], name: "arpKeySync", path: \.arpKeySync, writable: true),
            Entry(bytes: [33], name: "arpType", path: \.arpType, writable: true),
            Entry(bytes: [33], name: "arpRange", path: \.arpRange, writable: true),
            Entry(bytes: [34], name: "arpGate", path: \.arpGate, writable: true),
            Entry(bytes: [35], name: "arpResolution", path: \.arpResolution, writable: true),
            Entry(bytes: [36], name: "arpSwing", path: \.arpSwing, writable: true),
            Entry(bytes: [37], name: "kbdOctave", path: \.kbdOctave, writable: true),

            // TABLE 2 — Timbre 1 (absolute = 38 + chart offset)
            Entry(bytes: [t1 + 0], name: "midiChannel", path: \.midiChannel, writable: true, reservedOnS: true, scope: .timbre),
            Entry(bytes: [t1 + 1], name: "assignMode", path: \.assignMode, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 1], name: "eg1Reset", path: \.eg1Reset, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 1], name: "eg2Reset", path: \.eg2Reset, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 1], name: "triggerModeMulti", path: \.triggerModeMulti, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 1], name: "keyPriority", path: \.keyPriority, writable: true, reservedOnS: true, scope: .timbre),
            Entry(bytes: [t1 + 2], name: "unisonDetune", path: \.unisonDetune, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 3], name: "pitchTune", path: \.pitchTune, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 4], name: "bendRange", path: \.bendRange, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 5], name: "pitchTranspose", path: \.pitchTranspose, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 6], name: "vibratoIntensity", path: \.vibratoIntensity, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 7], name: "osc1Wave", path: \.osc1Wave, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 8], name: "osc1Control1", path: \.osc1Control1, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 9], name: "osc1Control2", path: \.osc1Control2, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 10], name: "dwgsWave", path: \.dwgsWave, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 12], name: "osc2Wave", path: \.osc2Wave, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 12], name: "osc2Mod", path: \.osc2Mod, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 13], name: "osc2Semitone", path: \.osc2Semitone, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 14], name: "osc2Tune", path: \.osc2Tune, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 15], name: "portamento", path: \.portamento, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 16], name: "osc1Level", path: \.osc1Level, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 17], name: "osc2Level", path: \.osc2Level, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 18], name: "noiseLevel", path: \.noiseLevel, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 19], name: "filterType", path: \.filterType, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 20], name: "filterCutoff", path: \.filterCutoff, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 21], name: "filterResonance", path: \.filterResonance, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 22], name: "filterEG1Intensity", path: \.filterEG1Intensity, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 23], name: "filterVelocitySense", path: \.filterVelocitySense, writable: true, reservedOnS: true, scope: .timbre),
            Entry(bytes: [t1 + 24], name: "filterKeyboardTrack", path: \.filterKeyboardTrack, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 25], name: "ampLevel", path: \.ampLevel, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 26], name: "panpot", path: \.panpot, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 27], name: "ampDistortion", path: \.ampDistortion, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 28], name: "ampVelocitySense", path: \.ampVelocitySense, writable: true, reservedOnS: true, scope: .timbre),
            Entry(bytes: [t1 + 29], name: "ampKeyboardTrack", path: \.ampKeyboardTrack, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 30], name: "eg1Attack", path: \.eg1Attack, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 31], name: "eg1Decay", path: \.eg1Decay, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 32], name: "eg1Sustain", path: \.eg1Sustain, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 33], name: "eg1Release", path: \.eg1Release, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 34], name: "eg2Attack", path: \.eg2Attack, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 35], name: "eg2Decay", path: \.eg2Decay, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 36], name: "eg2Sustain", path: \.eg2Sustain, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 37], name: "eg2Release", path: \.eg2Release, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 38], name: "lfo1Wave", path: \.lfo1Wave, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 38], name: "lfo1KeySync", path: \.lfo1KeySync, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 39], name: "lfo1Frequency", path: \.lfo1Frequency, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 40], name: "lfo1TempoSync", path: \.lfo1TempoSync, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 40], name: "lfo1SyncNote", path: \.lfo1SyncNote, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 41], name: "lfo2Wave", path: \.lfo2Wave, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 41], name: "lfo2KeySync", path: \.lfo2KeySync, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 42], name: "lfo2Frequency", path: \.lfo2Frequency, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 43], name: "lfo2TempoSync", path: \.lfo2TempoSync, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 43], name: "lfo2SyncNote", path: \.lfo2SyncNote, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 44], name: "patch1Source", path: \.patch1Source, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 44], name: "patch1Destination", path: \.patch1Destination, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 45], name: "patch1Intensity", path: \.patch1Intensity, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 46], name: "patch2Source", path: \.patch2Source, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 46], name: "patch2Destination", path: \.patch2Destination, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 47], name: "patch2Intensity", path: \.patch2Intensity, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 48], name: "patch3Source", path: \.patch3Source, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 48], name: "patch3Destination", path: \.patch3Destination, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 49], name: "patch3Intensity", path: \.patch3Intensity, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 50], name: "patch4Source", path: \.patch4Source, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 50], name: "patch4Destination", path: \.patch4Destination, writable: true, scope: .timbre),
            Entry(bytes: [t1 + 51], name: "patch4Intensity", path: \.patch4Intensity, writable: true, scope: .timbre),
        ]
        return list
    }()
}

#Preview {
    EditorView(bankNumber: 0, patchNumber: 1)
}
