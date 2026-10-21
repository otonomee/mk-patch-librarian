import XCTest
import SwiftUI
import AppKit
@testable import UIViews

/// Render probe: host BankBrowserView in a real window and dump the actual
/// NSView geometry. The shipped app renders only the first row (A01..D01) —
/// this distinguishes "only 4 cells built" from "cells built but misplaced".
final class BankBrowserGridProbeTests: XCTestCase {

    private struct Node {
        let className: String
        let frame: NSRect   // in window coordinates (y up)
    }

    private func walk(_ view: NSView, origin: NSPoint, into out: inout [Node]) {
        let local = view.frame.origin
        let absolute = NSPoint(x: origin.x + local.x, y: origin.y + local.y)
        out.append(Node(className: String(describing: type(of: view)),
                        frame: NSRect(origin: absolute, size: view.frame.size)))
        for sub in view.subviews {
            walk(sub, origin: absolute, into: &out)
        }
    }

    func testGridRendersAll128Cells() throws {
        let names = (0..<128).map { String(format: "P%03d", $0) }
        let view = BankBrowserView(programNames: names)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        // Pump SwiftUI's async layout passes.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded()

        var nodes: [Node] = []
        walk(host, origin: .zero, into: &nodes)

        print("PROBE total NSViews: \(nodes.count)")
        print("PROBE full tree (y is AppKit top-down):")
        for node in nodes {
            print(String(format: "  %@  x=%.0f y=%.0f w=%.0f h=%.0f",
                         node.className,
                         node.frame.origin.x, node.frame.origin.y,
                         node.frame.size.width, node.frame.size.height))
        }

        // Cell candidates: each cell is a Button, which AppKit represents
        // as a KeyViewProxy/_FocusRingView pair regardless of how deeply
        // it's nested — unlike raw frame geometry, this survives the grid
        // now living inside a second, inner NSHostingView (the custom
        // scrollbar's NSScrollView wrapper — see ThemedScrollView), whose
        // coordinate nesting the old width/height rect filter no longer
        // reliably sees through.
        let cells = nodes.filter { $0.className == "_FocusRingView" }
        print("PROBE cell-sized views: \(cells.count)")
        for node in cells.prefix(10) {
            print(String(format: "  %@  x=%.0f y=%.0f w=%.0f h=%.0f",
                         node.className,
                         node.frame.origin.x, node.frame.origin.y,
                         node.frame.size.width, node.frame.size.height))
        }

        // Deepest y any descendant reaches (window coords, y up).
        let maxY = nodes.map { $0.frame.maxY }.max() ?? 0
        let minY = nodes.map { $0.frame.minY }.min() ?? 0
        print("PROBE descendant y range: \(minY) .. \(maxY) (window height 900)")

        // Class-name histogram for the biggest contributors.
        let histogram = Dictionary(grouping: nodes, by: \.className)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
            .prefix(8)
        print("PROBE class histogram:")
        for (name, count) in histogram { print("  \(count)x \(name)") }

        // Pass criterion: at least 128 cell-sized views laid out.
        XCTAssertGreaterThanOrEqual(
            cells.count, 128,
            "only \(cells.count) cell-sized views for 128 programs; maxY=\(maxY)"
        )

        window.orderOut(nil)
    }
}
