import SwiftUI
import AppKit

/// SwiftUI buttons on macOS don't switch the cursor to a pointing hand on
/// hover the way web buttons do. This closes that gap for any clickable
/// control — push on hover-in, pop on hover-out.
private struct PointerCursorModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering && isEnabled {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

extension View {
    /// Shows the pointing-hand cursor while hovering this view.
    func pointerCursor() -> some View {
        modifier(PointerCursorModifier())
    }
}

/// Same gap, different symptom: macOS SwiftUI buttons jump straight from
/// idle to pressed with nothing in between, where a web button gets a
/// subtle hover background first. This adds that in-between state — a
/// faint overlay while the pointer is over the control, cleared on press
/// or exit.
private struct HoverHighlightModifier: ViewModifier {
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var cornerRadius: CGFloat
    var activeOpacity: Double

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white.opacity(isHovering && isEnabled ? activeOpacity : 0))
                    .allowsHitTesting(false)
            )
            .onHover { isHovering = $0 }
    }
}

extension View {
    /// A faint background highlight while hovering, layered on top so it
    /// works whether the control underneath is filled or plain.
    func hoverHighlight(cornerRadius: CGFloat = 6, activeOpacity: Double = 0.08) -> some View {
        modifier(HoverHighlightModifier(cornerRadius: cornerRadius, activeOpacity: activeOpacity))
    }
}
