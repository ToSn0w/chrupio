// Renders brand option A: an orange #ff5b1f square tile, black border, hard black offset shadow and the black
// chevron-and-bars glyph. Writes Resources/AppIcon.icns and the Chrome extension's icon16/48/128.png.
// Usage, from the repo root: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let orange = NSColor(srgbRed: 1, green: 0x5B / 255.0, blue: 0x1F / 255.0, alpha: 1)

/// The mockup's CSS geometry in pixels: cell, tile content box, border, shadow offset and glyph box.
struct Geometry { let cell, content, border, shadow, glyph: CGFloat }
let large = Geometry(cell: 256, content: 192, border: 8, shadow: 12, glyph: 138)

/// A hand-snapped tile for 16 and 32 px, in whole pixels from the top left: the tile's outer size, its border
/// and shadow, the chevron (rows of `chevronWidth` pixels stepping one pixel right per row, then back) and the bars.
/// At these sizes the scaled vector glyph blurs the three bars into one shape; whole pixels keep them apart.
struct PixelTile {
    let outer, border, shadow: Int
    let chevronX, chevronTop, chevronSteps, chevronWidth: Int
    let bars: [(x: Int, y: Int, width: Int, height: Int)]
}
let pixelTiles: [Int: PixelTile] = [
    // 15 px tile, 1 px border and 1 px shadow; chevron 2 px wide over 7 rows; bars 1 px wide with 1 px gaps.
    16: PixelTile(outer: 15, border: 1, shadow: 1, chevronX: 2, chevronTop: 4, chevronSteps: 4, chevronWidth: 2,
                  bars: [(8, 6, 1, 3), (10, 4, 1, 7), (12, 5, 1, 5)]),
    // 30 px tile, 2 px border and 2 px shadow; chevron 4 px wide over 13 rows; bars 2 px wide with 2 px gaps.
    32: PixelTile(outer: 30, border: 2, shadow: 2, chevronX: 4, chevronTop: 8, chevronSteps: 7, chevronWidth: 4,
                  bars: [(16, 11, 2, 7), (20, 8, 2, 13), (24, 10, 2, 9)]),
]

func renderPixels(_ pixels: Int, _ t: PixelTile) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.shouldAntialias = false
    func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        NSRect(x: x, y: pixels - y - h, width: w, height: h).fill()
    }
    NSColor.black.setFill()
    fill(t.shadow, t.shadow, t.outer, t.outer)
    fill(0, 0, t.outer, t.outer)
    orange.setFill()
    fill(t.border, t.border, t.outer - 2 * t.border, t.outer - 2 * t.border)
    NSColor.black.setFill()
    // An odd number of rows, so the tip is one row on the tile's centre line.
    let bottom = t.chevronTop + 2 * (t.chevronSteps - 1)
    for i in 0..<t.chevronSteps {
        fill(t.chevronX + i, t.chevronTop + i, t.chevronWidth, 1)
        fill(t.chevronX + i, bottom - i, t.chevronWidth, 1)
    }
    for bar in t.bars { fill(bar.x, bar.y, bar.width, bar.height) }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func render(_ pixels: Int) -> Data {
    if let tile = pixelTiles[pixels] { return renderPixels(pixels, tile) }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let g = large
    let scale = CGFloat(pixels) / g.cell
    // Top-left origin, like the SVG and CSS the design came from.
    let flip = NSAffineTransform()
    flip.translateX(by: 0, yBy: CGFloat(pixels))
    flip.scaleX(by: scale, yBy: -scale)
    flip.concat()

    // CSS centres the bordered box and draws the shadow outside the layout.
    let outer = g.content + 2 * g.border
    let origin = (g.cell - outer) / 2
    let tile = NSRect(x: origin, y: origin, width: outer, height: outer)
    NSColor.black.setFill()
    tile.offsetBy(dx: g.shadow, dy: g.shadow).fill()
    tile.fill()
    orange.setFill()
    tile.insetBy(dx: g.border, dy: g.border).fill()

    // The glyph's 100-unit box, centred in the tile.
    let place = NSAffineTransform()
    place.translateX(by: tile.midX - g.glyph / 2, yBy: tile.midY - g.glyph / 2)
    place.scale(by: g.glyph / 100)
    place.concat()
    NSColor.black.set()
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: 12, y: 26))
    chevron.line(to: NSPoint(x: 36, y: 50))
    chevron.line(to: NSPoint(x: 12, y: 74))
    chevron.lineWidth = 15
    chevron.lineCapStyle = .square
    chevron.lineJoinStyle = .miter
    chevron.stroke()
    for bar in [NSRect(x: 48, y: 38, width: 11, height: 24), NSRect(x: 64, y: 25, width: 11, height: 50), NSRect(x: 80, y: 34, width: 11, height: 32)] {
        bar.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in entries {
    try render(pixels).write(to: iconset.appendingPathComponent("\(name).png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

for pixels in [16, 48, 128] {
    try render(pixels).write(to: root.appendingPathComponent("extension/icons/icon\(pixels).png"))
}
print("Wrote Resources/AppIcon.icns and extension/icons/icon16, icon48, icon128")
