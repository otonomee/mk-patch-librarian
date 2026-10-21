import SwiftUI
import Models
import PBAPI

/// Same graphite/icy-aqua family as the Bank Browser, scoped to this screen
/// (each screen owns its palette; the editor's PatchTheme is off-limits).
private enum SettingsPalette {
    static let windowBG = Color(red: 0x21 / 255.0, green: 0x25 / 255.0, blue: 0x2b / 255.0)
    static let cardBG = Color(red: 0x2b / 255.0, green: 0x30 / 255.0, blue: 0x38 / 255.0)
    static let divider = Color.white.opacity(0.06)
    static let icyAqua = Color(red: 0xb8 / 255.0, green: 0xf2 / 255.0, blue: 0xe6 / 255.0)
    static let eggshell = Color(red: 0xfa / 255.0, green: 0xf3 / 255.0, blue: 0xdd / 255.0)
    static let mintLeaf = Color(red: 0x09 / 255.0, green: 0xbc / 255.0, blue: 0x8a / 255.0)
    static let blueSlate = Color(red: 0x5e / 255.0, green: 0x64 / 255.0, blue: 0x72 / 255.0)
    static let amber = Color(red: 0xf2 / 255.0, green: 0xb8 / 255.0, blue: 0x5c / 255.0)
    static let errorRed = Color(red: 0xf2 / 255.0, green: 0x7a / 255.0, blue: 0x6e / 255.0)
}

private enum SettingsFont {
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
        .custom(weight == .regular ? "JetBrainsMono-Regular" : "JetBrainsMono-SemiBold", size: size)
    }
}

/// Settings window: the MIDI connection (live status, rescan, an optional
/// preferred port) and the synth's own global settings, read on open and
/// written back only by an explicit Save.
public struct SettingsView: View {

    /// True while another long MIDI exchange (a bank load) owns the port;
    /// a settings read would clear its receive buffer mid-transfer.
    let isMIDIBusy: Bool

    @StateObject private var model = SynthSettingsModel()

    private enum Connection: Equatable {
        case searching
        case connected(String)
        case notFound
    }

    @State private var connection: Connection = .searching
    @State private var destinationNames: [String] = []
    @State private var preferredName: String = DeviceLocator.preferredDestinationName ?? ""

    public init(isMIDIBusy: Bool = false) {
        self.isMIDIBusy = isMIDIBusy
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            connectionCard
            synthCard
        }
        .padding(20)
        .frame(width: 540)
        .background(SettingsPalette.windowBG)
        .preferredColorScheme(.dark)
        .onAppear {
            refreshDestinations()
            resolveConnection(forceRescan: false)
            loadIfIdle()
        }
        .onChange(of: isMIDIBusy) { _, busy in
            if !busy { loadIfIdle() }
        }
    }

    // MARK: Connection

    private var connectionCard: some View {
        card(title: "MIDI Connection") {
            row {
                HStack(spacing: 8) {
                    connectionIndicator
                    Text(connectionText)
                        .font(SettingsFont.inter(13, weight: .medium))
                        .foregroundColor(connectionColor)
                }
                Spacer()
                actionButton("Rescan", icon: "arrow.clockwise", prominent: false,
                             disabled: connection == .searching) {
                    resolveConnection(forceRescan: true)
                }
            }
            divider
            row {
                rowLabel("Preferred port")
                Spacer()
                Picker("", selection: $preferredName) {
                    Text("Automatic").tag("")
                    Divider()
                    ForEach(pickerNames, id: \.self) { name in
                        Text(destinationNames.contains(name) ? name : "\(name) (not connected)").tag(name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .onChange(of: preferredName) { _, name in
                    DeviceLocator.preferredDestinationName = name.isEmpty ? nil : name
                    resolveConnection(forceRescan: true)
                }
            }
            caption("\(destinationNames.count) MIDI destination\(destinationNames.count == 1 ? "" : "s") found. "
                    + "The preferred port is tried first; if the synth doesn't answer there, "
                    + "every other port is searched automatically.")
        }
    }

    @ViewBuilder
    private var connectionIndicator: some View {
        if connection == .searching {
            ProgressView().controlSize(.mini).frame(width: 8, height: 8)
        } else {
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)
        }
    }

    private var connectionText: String {
        switch connection {
        case .searching: return "Searching for microKORG…"
        case .connected(let name): return "Connected via \(name)"
        case .notFound: return "microKORG not found"
        }
    }

    private var connectionColor: Color {
        switch connection {
        case .searching: return SettingsPalette.blueSlate
        case .connected: return SettingsPalette.mintLeaf
        case .notFound: return SettingsPalette.errorRed
        }
    }

    /// Unique destination names, plus a pinned name that's currently
    /// unplugged so the picker can still show what's selected.
    private var pickerNames: [String] {
        if !preferredName.isEmpty, !destinationNames.contains(preferredName) {
            return destinationNames + [preferredName]
        }
        return destinationNames
    }

    private func refreshDestinations() {
        var seen = Set<String>()
        destinationNames = MIDIOutputPort.getConnectedDevices()
            .filter(\.isDestination)
            .map(\.name)
            .filter { seen.insert($0).inserted }
    }

    private func resolveConnection(forceRescan: Bool) {
        if forceRescan {
            DeviceLocator.resetCache()
            refreshDestinations()
        } else if let cached = DeviceLocator.cachedDestination() {
            connection = .connected(cached.name)
            return
        }
        connection = .searching
        DeviceLocator.findDestination { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let dest): connection = .connected(dest.name)
                case .failure: connection = .notFound
                }
            }
        }
    }

    // MARK: Synth globals

    private var synthCard: some View {
        card(title: "microKORG Global Settings") {
            Group {
                row {
                    rowLabel("MIDI channel")
                    Spacer()
                    whenLoaded {
                        Picker("", selection: channelBinding) {
                            ForEach(0..<16, id: \.self) { ch in
                                Text("Channel \(ch + 1)").tag(UInt8(ch))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
                if let draft = model.draft, draft.midiChannel != KorgSysEx.channel {
                    caption("MK Patch Librarian talks to the synth on channel 1 only. Saving another channel "
                            + "will stop it reaching the synth until you set it back on the hardware.",
                            color: SettingsPalette.amber)
                }
                divider
                row {
                    rowLabel("Master tune")
                    Spacer()
                    if let draft = model.draft {
                        Text(String(format: "%+d ¢", draft.masterTune))
                            .font(SettingsFont.mono(12))
                            .foregroundColor(.secondary)
                    }
                    valueText(model.draft.map {
                        String(format: "%.1f Hz", GlobalSettings.masterTuneHz(cents: $0.masterTune))
                    })
                    Stepper("", value: intBinding(\.masterTune) { $0.setMasterTune($1) }, in: -100...100)
                        .labelsHidden()
                        .opacity(model.isLoaded ? 1 : 0.3)
                }
                divider
                row {
                    rowLabel("Transpose")
                    Spacer()
                    valueText(model.draft.map { String(format: "%+d st", $0.transpose) })
                    Stepper("", value: intBinding(\.transpose) { $0.setTranspose($1) }, in: -12...12)
                        .labelsHidden()
                        .opacity(model.isLoaded ? 1 : 0.3)
                }
                divider
                row {
                    rowLabel("Velocity curve")
                    Spacer()
                    whenLoaded {
                        Picker("", selection: velocityCurveBinding) {
                            ForEach(0..<GlobalSettings.velocityCurveCount, id: \.self) { curve in
                                let label = GlobalSettings.velocityCurveLabel(UInt8(curve))
                                Text(label == "Const" ? "Constant" : "Curve \(label)").tag(UInt8(curve))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
                if let draft = model.draft, draft.velocityCurve == GlobalSettings.velocityCurveConst {
                    row {
                        rowLabel("Constant velocity", indent: true)
                        Spacer()
                        valueText("\(draft.velocityValue)")
                        Stepper("", value: velocityValueBinding, in: 1...127)
                            .labelsHidden()
                    }
                }
            }
            Group {
                divider
                row {
                    rowLabel("Clock")
                    Spacer()
                    whenLoaded {
                        SettingsSegmented(selection: clockBinding,
                                          options: [(0, "Internal"), (1, "External"), (2, "Auto")],
                                          enabled: controlsEnabled)
                    }
                }
                divider
                row {
                    rowLabel("Local control")
                    Spacer()
                    whenLoaded {
                        SettingsSwitch(isOn: boolBinding(\.localControl) { $0.setLocalControl($1) },
                                       enabled: controlsEnabled)
                    }
                }
                divider
                row {
                    rowLabel("Memory protect")
                    Spacer()
                    whenLoaded {
                        SettingsSwitch(isOn: boolBinding(\.memoryProtect) { $0.setMemoryProtect($1) },
                                       enabled: controlsEnabled)
                    }
                }
            }
            .disabled(!controlsEnabled)

            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.isBusy || (isMIDIBusy && !model.isLoaded) {
                ProgressView().controlSize(.small)
            }
            Text(footerText)
                .font(SettingsFont.inter(12, weight: .medium))
                .foregroundColor(model.statusIsError ? SettingsPalette.errorRed
                                 : model.status == "Saved to microKORG" ? SettingsPalette.mintLeaf
                                 : .secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if model.isDirty && model.isLoaded {
                actionButton("Revert", icon: "arrow.uturn.backward", prominent: false, disabled: model.isBusy) {
                    model.revert()
                }
            } else {
                actionButton("Reload", icon: "arrow.down.circle", prominent: false,
                             disabled: model.isBusy || isMIDIBusy) {
                    model.load()
                }
            }
            actionButton("Save to microKORG", icon: "square.and.arrow.down", prominent: true,
                         disabled: !model.canSave || isMIDIBusy) {
                model.save()
            }
        }
        .padding(.top, 14)
    }

    private var footerText: String {
        if let status = model.status { return status }
        if isMIDIBusy && !model.isLoaded { return "Waiting for the bank load to finish…" }
        if model.isDirty { return "Unsaved changes" }
        if model.isLoaded { return "Read from the synth. Changes are only sent when you save." }
        return ""
    }

    private var controlsEnabled: Bool { model.isLoaded && !model.isBusy }

    /// Until the synth has answered, a control would have to show *some*
    /// value — a confident wrong one. Show an em dash instead.
    @ViewBuilder
    private func whenLoaded<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if model.isLoaded {
            content()
        } else {
            valueText(nil)
        }
    }

    private func loadIfIdle() {
        guard !isMIDIBusy, !model.isBusy, !model.isDirty else { return }
        model.load()
    }

    // MARK: Bindings (inert until the synth has answered)

    private var channelBinding: Binding<UInt8> {
        Binding(get: { model.draft?.midiChannel ?? 0 },
                set: { v in model.edit { $0.setMidiChannel(v) } })
    }

    private var velocityCurveBinding: Binding<UInt8> {
        Binding(get: { model.draft?.velocityCurve ?? 0 },
                set: { v in model.edit { $0.setVelocityCurve(v) } })
    }

    private var velocityValueBinding: Binding<Int> {
        Binding(get: { Int(model.draft?.velocityValue ?? 64) },
                set: { v in model.edit { $0.setVelocityValue(UInt8(max(1, min(127, v)))) } })
    }

    private var clockBinding: Binding<UInt8> {
        Binding(get: { model.draft?.clock ?? 0 },
                set: { v in model.edit { $0.setClock(v) } })
    }

    private func intBinding(_ key: KeyPath<GlobalSettings, Int>,
                            set: @escaping (inout GlobalSettings, Int) -> Void) -> Binding<Int> {
        Binding(get: { model.draft?[keyPath: key] ?? 0 },
                set: { v in model.edit { set(&$0, v) } })
    }

    private func boolBinding(_ key: KeyPath<GlobalSettings, Bool>,
                             set: @escaping (inout GlobalSettings, Bool) -> Void) -> Binding<Bool> {
        Binding(get: { model.draft?[keyPath: key] ?? false },
                set: { v in model.edit { set(&$0, v) } })
    }

    // MARK: Building blocks

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(SettingsFont.inter(11, weight: .semibold))
                .foregroundColor(SettingsPalette.icyAqua)
                .textCase(.uppercase)
                .tracking(0.8)
                .padding(.bottom, 10)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(SettingsPalette.cardBG))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.05), lineWidth: 1))
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .frame(minHeight: 30)
    }

    private var divider: some View {
        Rectangle().fill(SettingsPalette.divider).frame(height: 1).padding(.vertical, 4)
    }

    private func rowLabel(_ text: String, indent: Bool = false) -> some View {
        Text(text)
            .font(SettingsFont.inter(13))
            .foregroundColor(SettingsPalette.eggshell)
            .padding(.leading, indent ? 14 : 0)
    }

    /// Shows an em dash, not a default, until the synth has answered.
    private func valueText(_ text: String?) -> some View {
        Text(text ?? "—")
            .font(SettingsFont.mono(12, weight: .medium))
            .foregroundColor(text == nil ? .secondary : SettingsPalette.icyAqua)
            .monospacedDigit()
    }

    private func caption(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(SettingsFont.inter(11))
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
            .padding(.bottom, 4)
    }

    private func actionButton(_ title: String, icon: String, prominent: Bool, disabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(SettingsFont.inter(12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .foregroundColor(prominent ? SettingsPalette.windowBG : SettingsPalette.icyAqua)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(prominent ? SettingsPalette.icyAqua : SettingsPalette.windowBG)
        )
        .opacity(disabled ? 0.4 : 1)
        .disabled(disabled)
        .pointerCursor()
    }
}

/// Native NSSwitch ignores tint (HANDOFF-v18 §6), so draw one.
private struct SettingsSwitch: View {
    @Binding var isOn: Bool
    let enabled: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule()
                .fill(isOn && enabled ? SettingsPalette.icyAqua : SettingsPalette.windowBG)
                .frame(width: 34, height: 19)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                .overlay(
                    Circle()
                        .fill(isOn && enabled ? SettingsPalette.windowBG : SettingsPalette.blueSlate)
                        .frame(width: 14, height: 14)
                        .offset(x: isOn ? 7.5 : -7.5)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .pointerCursor()
        .animation(.easeInOut(duration: 0.12), value: isOn)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Palette-matched replacement for `.pickerStyle(.segmented)`, whose
/// system-blue selection fights the icy-aqua accent.
private struct SettingsSegmented: View {
    @Binding var selection: UInt8
    let options: [(UInt8, String)]
    let enabled: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let isSelected = value == selection
                Button { selection = value } label: {
                    Text(title)
                        .font(SettingsFont.inter(12, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? SettingsPalette.windowBG : SettingsPalette.eggshell.opacity(0.8))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(isSelected ? SettingsPalette.icyAqua : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .pointerCursor()
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(SettingsPalette.windowBG))
        .opacity(enabled ? 1 : 0.5)
    }
}
