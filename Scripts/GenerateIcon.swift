import AppKit

// App icon per the design brief: deep-space-blue background, a stylized
// icy-aqua waveform (not literal "MK" lettering, which reads badly at icon
// sizes anyway), flat vector style.

let deepSpaceBlue = NSColor(red: 0x17/255.0, green: 0x2a/255.0, blue: 0x3a/255.0, alpha: 1)
let icyAqua = NSColor(red: 0xb8/255.0, green: 0xf2/255.0, blue: 0xe6/255.0, alpha: 1)

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS auto-masks app icons to its own rounded-square shape, so the
// background only needs to be a plain square fill, not pre-rounded.
let bgRect = NSRect(x: 0, y: 0, width: size, height: size)
deepSpaceBlue.setFill()
bgRect.fill()

// A 7-bar waveform/EQ glyph, centered, varying heights, rounded caps —
// reads as "audio" at a glance without needing literal text.
let barCount = 7
let barWidth = size * 0.07
let gap = size * 0.045
let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
let startX = (size - totalWidth) / 2
// Relative heights (0-1 of the max bar envelope), center-weighted like a
// waveform — short, taller, tallest in the middle, tapering back down.
let heights: [CGFloat] = [0.28, 0.55, 0.82, 1.0, 0.82, 0.55, 0.28]
let maxBarHeight = size * 0.46
let centerY = size / 2

icyAqua.setFill()
for i in 0..<barCount {
    let h = maxBarHeight * heights[i]
    let x = startX + CGFloat(i) * (barWidth + gap)
    let rect = NSRect(x: x, y: centerY - h / 2, width: barWidth, height: h)
    let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
    path.fill()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not render icon")
}

let outPath = CommandLine.arguments[1]
try! png.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath)")
