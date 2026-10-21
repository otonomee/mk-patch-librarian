import AppKit
import ImageIO

// App icon: deep-space-blue background, a stylized icy-aqua waveform (not
// literal "MK" lettering, which reads badly at icon sizes anyway).
//
// Usage:
//   swift Scripts/GenerateIcon.swift <out.png>               full-bleed opaque square, no alpha channel
//   swift Scripts/GenerateIcon.swift <out.png> --foreground  waveform only on transparency (Icon Composer layer)
//
// Renders into an explicit 1024×1024 pixel bitmap; NSImage.lockFocus would
// follow the screen's backing scale and emit 2048px on a Retina display.

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: GenerateIcon.swift <out.png> [--foreground]\n".data(using: .utf8)!)
    exit(1)
}
let outPath = args[1]
let foregroundOnly = args.contains("--foreground")

let deepSpaceBlue = NSColor(srgbRed: 0x17/255.0, green: 0x2a/255.0, blue: 0x3a/255.0, alpha: 1)
let icyAqua = NSColor(srgbRed: 0xb8/255.0, green: 0xf2/255.0, blue: 0xe6/255.0, alpha: 1)

let pixels = 1024
// noneSkipLast encodes to a PNG with no alpha channel at all, which App
// Store icon masters require; the foreground layer keeps its transparency.
guard let cg = CGContext(
    data: nil, width: pixels, height: pixels,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: foregroundOnly ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fatalError("Could not allocate bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)

let size = CGFloat(pixels)
if foregroundOnly {
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill(using: .copy)
} else {
    deepSpaceBlue.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
}

// A 7-bar waveform/EQ glyph, centered, center-weighted heights, rounded caps.
let barCount = 7
let barWidth = size * 0.07
let gap = size * 0.045
let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
let startX = (size - totalWidth) / 2
let heights: [CGFloat] = [0.28, 0.55, 0.82, 1.0, 0.82, 0.55, 0.28]
let maxBarHeight = size * 0.46
let centerY = size / 2

icyAqua.setFill()
for i in 0..<barCount {
    let h = maxBarHeight * heights[i]
    let x = startX + CGFloat(i) * (barWidth + gap)
    let rect = NSRect(x: x, y: centerY - h / 2, width: barWidth, height: h)
    NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
}

NSGraphicsContext.restoreGraphicsState()

guard let image = cg.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("Could not encode PNG")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("Could not write \(outPath)") }
print("Wrote \(outPath) (\(pixels)×\(pixels), alpha: \(foregroundOnly))")
