import SwiftUI

// MARK: - Theme — charcoal/camel body with a cool icy-aqua accent. The
// original canary-yellow accent ("amber") read as way too harsh/neon in
// practice ("someone ate a glow stick and vomited it out") despite the
// charcoal/camel body itself landing well — swapped the accent only,
// pulling from the same cool palette used in the import sheet
// (ImportProgramsView.ImportPalette) for consistency across the app.

enum PatchTheme {
    static let charcoal = Color(red: 0x4d / 255.0, green: 0x4d / 255.0, blue: 0x4c / 255.0)
    static let greyOlive = Color(red: 0x88 / 255.0, green: 0x81 / 255.0, blue: 0x73 / 255.0)
    static let camel = Color(red: 0xbf / 255.0, green: 0x9e / 255.0, blue: 0x83 / 255.0)
    static let icyAqua = Color(red: 0xb8 / 255.0, green: 0xf2 / 255.0, blue: 0xe6 / 255.0)
    static let dustGrey = Color(red: 0xdd / 255.0, green: 0xdc / 255.0, blue: 0xd7 / 255.0)

    /// Behind the cards — darker than charcoal so cards still read as
    /// elevated, but nowhere near black.
    static let windowBG = Color(red: 0x2a / 255.0, green: 0x2a / 255.0, blue: 0x29 / 255.0)
    /// Card background — charcoal itself.
    static let cardBG = charcoal
    /// Accent — icy-aqua, replacing the original canary-yellow "amber."
    static let accent = icyAqua
    /// Hairline around cards — grey-olive reads warmer than a flat white
    /// hairline against charcoal.
    static let cardBorder = greyOlive.opacity(0.35)
}

// MARK: - Dense matrix control grid
//
// Sections hand their controls to `ControlGrid` as cells instead of stacking
// full-width sliders in a `VStack`. Originally a fixed 2-column layout; now
// an auto-fit matrix (as many compact cells per row as fit) so a window full
// of parameters reads as a dense table instead of a handful of oversized
// cards per screen. Layout uses `Grid`/`GridRow` only — on this macOS a
// nested `ForEach` inside any lazy container renders just the first row
// (v9 §5, pinned by `LazyGridReproTests` + `BankBrowserGridProbeTests`).

/// One control slot in a `ControlGrid`: a label + control pair (or a
/// sub-header/note). `wide` cells always occupy a full row of their own.
struct ControlCell {
    let wide: Bool
    let content: AnyView

    init(wide: Bool = false, content: AnyView) {
        self.wide = wide
        self.content = content
    }
}

/// Non-lazy auto-fit matrix layout for one section's controls: as many
/// `minCellWidth`-ish columns per row as the available width allows,
/// recomputed as the window resizes. Always at least 1 column.
struct ControlGrid: View {

    let cells: [ControlCell]

    init(_ cells: [ControlCell]) {
        self.cells = cells
    }

    /// Target cell width used to decide how many columns fit. Cells still
    /// stretch to fill whatever's left over in the row.
    static let minCellWidth: CGFloat = 112

    /// Assumed width until the first layout pass measures the real one.
    @State private var contentWidth: CGFloat = 1200

    private var columnCount: Int {
        max(1, Int(contentWidth / Self.minCellWidth))
    }

    var body: some View {
        let rows = Self.rows(cells, columns: columnCount)
        // Fixed, not maxWidth: Grid sizes each column to its widest cell's
        // natural content, and `.frame(maxWidth:)` only caps growth — it
        // can't force a long label like "KEYBOARD TRACK" to shrink. An
        // explicit width makes the Text actually truncate (it already has
        // .lineLimit(1)) instead of the whole row overflowing into
        // whatever's next to it.
        let cellWidth = columnCount > 1
            ? max(68, (contentWidth - CGFloat(columnCount - 1) * 5) / CGFloat(columnCount))
            : contentWidth
        Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        cell.content
                            .frame(width: cell.wide ? nil : cellWidth, alignment: .leading)
                            .gridCellColumns(cell.wide ? columnCount : 1)
                    }
                }
            }
        }
        // Without this, the Grid sizes to whatever its own rows naturally
        // want and the background GeometryReader below just reports that
        // self-chosen width back — a circular measurement that converges on
        // "however many columns it already picked," not the space actually
        // available. Claiming the full offered width first breaks the
        // circularity: the reader now measures what the parent offered.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(key: ControlGridWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(ControlGridWidthKey.self) { width in
            if width > 0 { contentWidth = width }
        }
    }

    /// Chunk cells into rows: normal cells pair up to `columns` per row;
    /// `wide` cells get a row of their own. Pure — unit-tested in
    /// `ControlGridTests`.
    static func rows(_ cells: [ControlCell], columns: Int) -> [[ControlCell]] {
        var result: [[ControlCell]] = []
        var current: [ControlCell] = []
        for cell in cells {
            if cell.wide || current.count >= columns {
                if !current.isEmpty {
                    result.append(current)
                    current = []
                }
                if cell.wide {
                    result.append([cell])
                } else {
                    current.append(cell)
                }
            } else {
                current.append(cell)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

private struct ControlGridWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Readout formatting (v15 §3.3)
//
// Chart-cited display rules. The S chart's value tables describe 64-centered
// params as e.g. "64+/-63=0+/-63", and footnote *3-6 (`00,01~7F =
// -63,-63~+63`) floors even byte 00 at −63 — `MicroKORGProgram.signed64`
// alone would display −64 for byte 0, a value no chart table produces.
// Readouts therefore clamp to the slider's chart range; the STORED bytes are
// never clamped (round-trip fidelity is the model's job).
enum Readout {

    /// Signed (64-centered) value text, clamped to the chart range:
    /// "+12 st", "-3", "0".
    static func signed(_ value: Int, range: ClosedRange<Int>, unit: String = "") -> String {
        let clamped = max(range.lowerBound, min(range.upperBound, value))
        let sign = clamped > 0 ? "+" : ""
        return sign + "\(clamped)" + suffix(unit)
    }

    /// Raw 0..127 byte text: "87", "87 %".
    static func unsigned(_ byte: UInt8, unit: String = "") -> String {
        "\(Int(byte))" + suffix(unit)
    }

    /// Panpot text per TABLE 2 +26: `0~64~127 = L64~CNT~R63`.
    static func panpot(_ byte: UInt8) -> String {
        switch Int(byte) {
        case 64: return "CNT"
        case let v where v < 64: return "L\(64 - v)"
        default: return "R\(Int(byte) - 64)"
        }
    }

    private static func suffix(_ unit: String) -> String {
        unit.isEmpty ? "" : " \(unit)"
    }
}

// MARK: - Cell factories

extension View {
    /// `.help` only when text exists — an empty tooltip would be a bug.
    @ViewBuilder
    func tooltip(_ text: String) -> some View {
        if text.isEmpty { self } else { self.help(text) }
    }

    /// The matrix look every cell shares: tight padding, a hairline border,
    /// a slightly inset fill — so a row of these reads as a dense table/
    /// matrix of parameters, not a loose cluster of oversized sliders.
    func matrixBox() -> some View {
        self
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(PatchTheme.windowBG.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(PatchTheme.cardBorder, lineWidth: 1)
            )
    }
}

/// Label on the left, drag-to-scrub value on the right — one line, the way
/// the hardware panel prints "LABEL ... value" in its own parameter table.
/// Replaces the old label-row-then-slider-row cell: a full slider track
/// cost a whole second line per parameter for a window that needs to hold
/// ~100 of these without scrolling.
private func matrixRow<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
    HStack(spacing: 4) {
        Text(label)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(PatchTheme.dustGrey.opacity(0.8))
            .textCase(.uppercase)
            .lineLimit(1)
        Spacer(minLength: 2)
        value()
    }
}

/// Click-and-drag-to-adjust value text — no slider track, just the number
/// itself as the control (same idea as Xcode's scrubbable numeric fields).
/// Right/up increases, left/down decreases; `sensitivity` is points of drag
/// per 1 unit of change. Internal, not private — `PatchControls` in
/// EditorView.swift reuses it directly for a custom single-row layout the
/// standard matrix cells didn't fit well.
struct ScrubField: View {
    let text: String
    let sensitivity: CGFloat
    let onDelta: (Int) -> Void

    @State private var accumulated: CGFloat = 0
    @State private var isDragging = false

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
            .foregroundColor(isDragging ? PatchTheme.accent.opacity(0.7) : PatchTheme.accent)
            .lineLimit(1)
            .layoutPriority(1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        isDragging = true
                        let moved = g.translation.width - g.translation.height
                        accumulated += moved
                        let steps = Int(accumulated / sensitivity)
                        if steps != 0 {
                            onDelta(steps)
                            accumulated -= CGFloat(steps) * sensitivity
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        accumulated = 0
                    }
            )
            .pointerCursor()
    }
}

/// Drag-scrub bound to a raw 0..127 program byte. `readout` replaces the
/// default value text (Panpot, DWGS No., …). `param` looks up hover help in
/// `EditorHelp`; `help` overrides it for non-registry controls.
func byteSlider(
    _ label: String,
    value: Binding<UInt8>,
    param: String? = nil,
    help: String? = nil,
    readout: ((UInt8) -> String)? = nil
) -> ControlCell {
    let tip = EditorHelp.text(param: param, inline: help)
    return ControlCell(content: AnyView(
        matrixRow(label) {
            ScrubField(
                text: readout?(value.wrappedValue) ?? Readout.unsigned(value.wrappedValue),
                sensitivity: 3
            ) { delta in
                let proposed = Int(value.wrappedValue) + delta
                value.wrappedValue = UInt8(max(0, min(127, proposed)))
            }
        }
        .matrixBox()
        .tooltip(tip)
    ))
}

/// Drag-scrub bound to a signed (offset-binary) program value; the readout
/// shows the chart-range value (see `Readout.signed`).
func signedSlider(
    _ label: String,
    value: Binding<Int>,
    range: ClosedRange<Int>,
    unit: String = "",
    param: String? = nil,
    help: String? = nil
) -> ControlCell {
    let tip = EditorHelp.text(param: param, inline: help)
    return ControlCell(content: AnyView(
        matrixRow(label) {
            ScrubField(
                text: Readout.signed(value.wrappedValue, range: range, unit: unit),
                sensitivity: 3
            ) { delta in
                let proposed = value.wrappedValue + delta
                value.wrappedValue = max(range.lowerBound, min(range.upperBound, proposed))
            }
        }
        .matrixBox()
        .tooltip(tip)
    ))
}

/// Labeled picker for enum/step parameters. Few options (segmented) still
/// claim a full row — "Ring+Sync" doesn't survive being squeezed into a
/// one-of-six matrix column — but a longer list collapses to one line: a
/// menu button showing the current value, opened by clicking it, same
/// footprint as a slider cell instead of a header row plus a dropdown row.
func pickerCell<T: Hashable>(
    _ label: String,
    selection: Binding<T>,
    options: [(tag: T, title: String)],
    valueText: String? = nil,
    param: String? = nil,
    help: String? = nil
) -> ControlCell {
    let current = valueText
        ?? options.first { $0.tag == selection.wrappedValue }?.title
    let tip = EditorHelp.text(param: param, inline: help)
    let segmented = options.count <= 4
    if segmented {
        return ControlCell(wide: options.count > 2, content: AnyView(
            VStack(alignment: .leading, spacing: 3) {
                matrixRow(label) {
                    if let current {
                        Text(current)
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(PatchTheme.accent)
                            .lineLimit(1)
                    }
                }
                Picker("", selection: selection) {
                    ForEach(options, id: \.tag) { option in
                        Text(option.title).tag(option.tag)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
            .matrixBox()
            .tooltip(tip)
        ))
    }
    return ControlCell(content: AnyView(
        matrixRow(label) {
            Picker("", selection: selection) {
                ForEach(options, id: \.tag) { option in
                    Text(option.title).tag(option.tag)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .matrixBox()
        .tooltip(tip)
    ))
}

/// Small drawn switch, not a native `Toggle`. Neither `.tint()` nor the
/// explicit `SwitchToggleStyle(tint:)` actually changed the rendered color —
/// macOS's NSSwitch-backed `.switch` style follows the user's system-wide
/// accent color preference regardless of what SwiftUI is told, a known
/// platform quirk, not something more tint-modifier-guessing was going to
/// fix. Drawing it directly (same approach as the audition keyboard's keys)
/// gives real control over the color.
private struct MatrixToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? PatchTheme.accent : PatchTheme.windowBG)
            .frame(width: 28, height: 15)
            .overlay(Capsule().strokeBorder(PatchTheme.cardBorder, lineWidth: 1))
            .overlay(
                Circle()
                    .fill(isOn ? PatchTheme.windowBG : PatchTheme.dustGrey)
                    .frame(width: 11, height: 11)
                    .offset(x: isOn ? 6.5 : -6.5)
            )
            .contentShape(Rectangle())
            .onTapGesture { isOn.toggle() }
            .pointerCursor()
            .animation(.easeInOut(duration: 0.12), value: isOn)
    }
}

/// Labeled on/off switch, one line: label left, switch right.
func toggleCell(_ label: String, isOn: Binding<Bool>, param: String? = nil, help: String? = nil) -> ControlCell {
    let tip = EditorHelp.text(param: param, inline: help)
    return ControlCell(content: AnyView(
        matrixRow(label) {
            MatrixToggle(isOn: isOn)
        }
        .matrixBox()
        .tooltip(tip)
    ))
}

/// Labeled on/off switch.
func toggleCell(_ label: String, isOn: Binding<Bool>) -> ControlCell {
    ControlCell(content: AnyView(
        matrixRow(label) {
            MatrixToggle(isOn: isOn)
        }
        .matrixBox()
    ))
}

/// Sub-section heading spanning a full row (inside one card).
func headerCell(_ text: String) -> ControlCell {
    ControlCell(wide: true, content: AnyView(
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.secondary)
            .padding(.top, 2)
    ))
}

/// Full-row caption for contextual notes.
func noteCell(_ text: String) -> ControlCell {
    ControlCell(wide: true, content: AnyView(
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
    ))
}
