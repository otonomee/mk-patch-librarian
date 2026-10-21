import XCTest
import SwiftUI
import AppKit
@testable import UIViews

/// Minimal repro: which grid arrangement materializes all rows?
///   A) flat single ForEach in LazyVGrid
///   B) nested ForEach in LazyVGrid (what BankBrowserView does)
///   C) non-lazy Grid with the same content
/// Materialized cells = Button NSView descendants (~64pt tall).
final class LazyGridReproTests: XCTestCase {

    private func materializedButtonCount(_ view: NSView) -> Int {
        var count = 0
        func walk(_ v: NSView) {
            let c = String(describing: type(of: v))
            if c == "_FocusRingView" || c == "KeyViewProxy" {
                // Toolbar buttons are 19-24pt; cells are 64pt.
                if v.frame.height >= 60 && v.frame.height <= 90,
                   v.frame.width >= 300 {
                    count += 1
                }
            }
            v.subviews.forEach(walk)
        }
        walk(view)
        return count / 2   // focus ring + key proxy per button
    }

    private func render(_ view: some View) -> NSHostingView<some View> {
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
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded()
        window.orderOut(nil)
        return host
    }

    private let columns = Array(repeating: GridItem(.flexible()), count: 4)

    private func cell(_ title: String) -> some View {
        Button {} label: {
            VStack(spacing: 4) {
                Text(title)
                Text("—").font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.plain)
    }

    func testA_flatForEach() {
        let host = render(ScrollView {
            LazyVGrid(columns: columns) {
                ForEach(0..<128, id: \.self) { i in
                    self.cell("A\(i)")
                }
            }.padding()
        })
        print("REPRO A flat LazyVGrid: \(materializedButtonCount(host)) / 128")
    }

    func testB_nestedForEach() {
        let host = render(ScrollView {
            LazyVGrid(columns: columns) {
                ForEach(0..<32, id: \.self) { patch in
                    ForEach(0..<4, id: \.self) { bank in
                        self.cell("B\(bank)\(patch)")
                    }
                }
            }.padding()
        })
        print("REPRO B nested LazyVGrid: \(materializedButtonCount(host)) / 128")
    }

    func testC_nonLazyGrid() {
        let host = render(ScrollView {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(0..<32, id: \.self) { patch in
                    GridRow {
                        ForEach(0..<4, id: \.self) { bank in
                            self.cell("C\(bank)\(patch)")
                        }
                    }
                }
            }.padding()
        })
        print("REPRO C non-lazy Grid: \(materializedButtonCount(host)) / 128")
    }
}
