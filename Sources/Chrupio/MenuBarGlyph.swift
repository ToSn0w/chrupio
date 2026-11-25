import AppKit

/// The menu-bar mark, brand option 2: the logo's chevron and three bars, drawn heavier so it reads at 16 pt.
/// A template image, so macOS tints it for light and dark menu bars and for the highlighted state.
/// Hand-snapped to whole pixels at 1x (16 px) and 2x (32 px), so the chevron and bars stay sharp and separate.
@MainActor
enum MenuBarGlyph {
    /// Whole-pixel geometry from the top left: the chevron's rows of `chevronWidth` pixels step one pixel right
    /// per row down to a two-row tip, then back; bars are filled rectangles.
    private struct Grid {
        let pixels, chevronTop, chevronSteps, chevronWidth: Int
        let bars: [(x: Int, y: Int, width: Int, height: Int)]
    }

    private static let grids = [
        // Chevron 3 px wide over 10 rows; bars 2 px wide with 1 px gaps, 4, 10 and 6 px tall.
        Grid(pixels: 16, chevronTop: 3, chevronSteps: 5, chevronWidth: 3,
             bars: [(8, 6, 2, 4), (11, 3, 2, 10), (14, 5, 2, 6)]),
        // Chevron 6 px wide over 20 rows; bars 4 px wide with 2 px gaps, 8, 20 and 12 px tall.
        Grid(pixels: 32, chevronTop: 6, chevronSteps: 10, chevronWidth: 6,
             bars: [(16, 12, 4, 8), (22, 6, 4, 20), (28, 10, 4, 12)]),
    ]

    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        for grid in grids {
            image.addRepresentation(representation(grid))
        }
        image.isTemplate = true
        image.accessibilityDescription = "Chrupio"
        return image
    }()

    private static func representation(_ grid: Grid) -> NSBitmapImageRep {
        let pixels = grid.pixels
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.shouldAntialias = false
        NSColor.black.setFill()
        func fill(_ x: Int, _ y: Int, _ width: Int, _ height: Int) {
            NSRect(x: x, y: pixels - y - height, width: width, height: height).fill()
        }
        let bottom = grid.chevronTop + 2 * grid.chevronSteps - 1
        for step in 0..<grid.chevronSteps {
            fill(step, grid.chevronTop + step, grid.chevronWidth, 1)
            fill(step, bottom - step, grid.chevronWidth, 1)
        }
        for bar in grid.bars {
            fill(bar.x, bar.y, bar.width, bar.height)
        }
        NSGraphicsContext.restoreGraphicsState()
        // Set after drawing, so drawing above is in pixels; this makes the 32 px version the 2x representation.
        rep.size = NSSize(width: 16, height: 16)
        return rep
    }
}
