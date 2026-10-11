import AppKit

// Draws the app icon: a graphite tile with the notch at the top and the one thing in Do Now below it.
// Usage: swift scripts/make-icon.swift <output.iconset>

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    let s = CGFloat(pixels) / 1024

    // Apple's icon grid: an 824-point tile with 185-point corners and a soft shadow.
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    cg.addPath(tilePath)
    cg.setFillColor(NSColor(white: 0.1, alpha: 1).cgColor)
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(tilePath)
    cg.clip()
    let shades = [NSColor(white: 0.24, alpha: 1).cgColor, NSColor(white: 0.07, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: shades, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    let notchWidth = 300 * s, notchHeight = 92 * s, notchRadius = 40 * s
    let notch = CGRect(x: tile.midX - notchWidth / 2, y: tile.maxY - notchHeight, width: notchWidth, height: notchHeight + notchRadius)
    cg.addPath(CGPath(roundedRect: notch, cornerWidth: notchRadius, cornerHeight: notchRadius, transform: nil))
    cg.setFillColor(NSColor.black.cgColor)
    cg.fillPath()
    cg.restoreGState()

    let center = CGPoint(x: tile.midX, y: tile.midY - 40 * s)
    let ring = 190 * s
    cg.setStrokeColor(NSColor(srgbRed: 1, green: 0.64, blue: 0.24, alpha: 1).cgColor)
    cg.setLineWidth(64 * s)
    cg.strokeEllipse(in: CGRect(x: center.x - ring, y: center.y - ring, width: ring * 2, height: ring * 2))
    let dot = 62 * s
    cg.setFillColor(NSColor.white.cgColor)
    cg.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, pixels) in variants {
    try render(pixels: pixels).write(to: output.appendingPathComponent("\(name).png"))
}
print("Wrote \(variants.count) icon sizes to \(output.path)")
