import SwiftUI

// MARK: - ADSR envelope picture (v15 §3.4 — view math only, no bytes)

/// Pure point math for the ADSR curve drawn above the Filter EG / Amp EG
/// sliders. Values are the raw 0..127 byte scales; y grows downward like
/// screen coordinates (level 127 → top, level 0 → bottom). Phase widths are
/// proportional to the A/D/R values; the sustain phase holds a fixed pseudo
/// time so a flat segment is always visible. Unit-tested in
/// `ADSRGeometryTests`.
enum ADSRCurve {

    /// Fixed sustain-hold "time" in the same 0..127 units, so the sustain
    /// segment never vanishes when A, D and R are 0.
    static let sustainHoldTime: Double = 20

    /// The five turning points: note-on (bottom) → attack peak → sustain
    /// level → end of hold → release to zero. x values are non-decreasing
    /// and always within 0...width.
    static func points(
        attack: Double,
        decay: Double,
        sustain: Double,
        release: Double,
        width: CGFloat,
        height: CGFloat
    ) -> [CGPoint] {
        let totalTime = attack + decay + release + sustainHoldTime
        let scale = totalTime > 0 ? CGFloat(width) / CGFloat(totalTime) : 0

        let attackWidth = CGFloat(attack) * scale
        let decayWidth = CGFloat(decay) * scale
        let holdWidth = CGFloat(sustainHoldTime) * scale

        func y(_ level: Double) -> CGFloat {
            height * (1 - CGFloat(max(0, min(127, level))) / 127)
        }

        let sustainY = y(sustain)
        let sustainStart = attackWidth + decayWidth

        return [
            CGPoint(x: 0, y: height),                             // note-on
            CGPoint(x: attackWidth, y: 0),                        // peak
            CGPoint(x: sustainStart, y: sustainY),                // decay target
            CGPoint(x: sustainStart + holdWidth, y: sustainY),    // hold end
            CGPoint(x: CGFloat(width), y: height),                // release end
        ]
    }
}

/// Amber ADSR curve (mockup accent) drawn from the four EG byte values.
/// Live: the section's sliders drive it through the shared `EditorState`.
struct ADSRCurveView: View {

    let attack: UInt8
    let decay: UInt8
    let sustain: UInt8
    let release: UInt8

    var body: some View {
        GeometryReader { geo in
            let points = ADSRCurve.points(
                attack: Double(attack),
                decay: Double(decay),
                sustain: Double(sustain),
                release: Double(release),
                width: geo.size.width,
                height: geo.size.height
            )
            let curve = Path { path in
                path.move(to: points[0])
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
            }
            ZStack {
                curve
                    .fill(
                        LinearGradient(
                            colors: [PatchTheme.accent.opacity(0.22), PatchTheme.accent.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                curve
                    .stroke(PatchTheme.accent, lineWidth: 1.5)
            }
        }
        .frame(height: 48)
    }
}
