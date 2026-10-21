import SwiftUI
import AppKit

/// A vertical `ScrollView` replacement with a custom-colored scrollbar.
///
/// SwiftUI's `ScrollView` has no API for scrollbar colors — that's a
/// CSS/WebKit-only concept (`::-webkit-scrollbar`), not something AppKit
/// exposes through simple modifiers. The real native equivalent is an
/// `NSScroller` subclass overriding its own drawing, hosted in an
/// `NSScrollView` wrapped for SwiftUI. `.legacy` scroller style is
/// required — macOS's modern overlay-only-when-scrolling scrollers mostly
/// bypass a custom subclass's drawing, so there'd be nothing to actually
/// recolor.
struct ThemedScrollView<Content: View>: NSViewRepresentable {
    private let trackColor: NSColor
    private let thumbColor: NSColor
    private let content: Content

    init(
        trackColor: Color,
        thumbColor: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.trackColor = NSColor(trackColor)
        self.thumbColor = NSColor(thumbColor)
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .legacy

        let scroller = ThemedScroller()
        scroller.trackColor = trackColor
        scroller.thumbColor = thumbColor
        scrollView.verticalScroller = scroller

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedHostView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: documentView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])

        scrollView.documentView = documentView
        // Without this, AutoLayout has no finite width to resolve the
        // document view against (NSScrollView doesn't infer it the way it
        // does for a plain unconstrained view), so SwiftUI's content gets
        // laid out at zero size — the grid rendered completely blank until
        // this was added. Height stays unconstrained so the document grows
        // to the content's natural height.
        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
        context.coordinator.hosting = hosting
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.hosting?.rootView = content
        if let scroller = scrollView.verticalScroller as? ThemedScroller {
            scroller.trackColor = trackColor
            scroller.thumbColor = thumbColor
            scroller.needsDisplay = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hosting: NSHostingView<Content>?
    }
}

/// Top-left-origin document view so SwiftUI content inside the scroller
/// lays out the same direction as everywhere else in the app (plain
/// `NSView` is bottom-left-origin, which flips a `VStack`'s natural
/// top-to-bottom growth upside down inside an `NSScrollView`).
private final class FlippedHostView: NSView {
    override var isFlipped: Bool { true }
}

private final class ThemedScroller: NSScroller {
    var trackColor: NSColor = .clear
    var thumbColor: NSColor = .gray

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnob() {
        let rect = self.rect(for: .knob).insetBy(dx: 2.5, dy: 1)
        guard rect.width > 0, rect.height > 0 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.width / 2)
        thumbColor.setFill()
        path.fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        trackColor.setFill()
        slotRect.fill()
    }
}
