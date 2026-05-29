import AppKit

/// Maps abstract `TerminalColor` values to concrete `NSColor`s for the render
/// layer, using the standard xterm 256-color palette.
///
/// RATIONALE: the ANSI/xterm palette values below are protocol-defined — they
/// are *what* a terminal color code means, not app UI chrome — so SPEC.md's
/// "use semantic `NSColor`s, no hardcoded RGB" rule does not apply here. The
/// default foreground/background match the previous `SerialTextView` styling.
@MainActor
enum TerminalTheme {
    static let defaultForeground = NSColor(white: 0.9, alpha: 1.0)
    static let defaultBackground = NSColor(white: 0.1, alpha: 1.0)
    /// Cursor block / outline color.
    static let cursor = NSColor(white: 0.9, alpha: 1.0)
    /// Selection highlight fill (matches SPEC.md's accent-at-low-opacity rule).
    static let selection = NSColor.controlAccentColor.withAlphaComponent(0.35)
    /// Find-match highlight fill.
    static let findHighlight = NSColor.systemYellow.withAlphaComponent(0.45)

    /// Resolves a cell color. `bold` brightens the low 8 ANSI foreground colors,
    /// matching common terminal behavior.
    static func color(for terminalColor: TerminalColor, foreground: Bool, bold: Bool) -> NSColor {
        switch terminalColor {
        case .default:
            return foreground ? defaultForeground : defaultBackground
        case .indexed(let raw):
            var index = Int(raw)
            if foreground && bold && index < 8 { index += 8 }
            return palette[index]
        case .rgb(let r, let g, let b):
            return NSColor(
                srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255,
                alpha: 1)
        }
    }

    /// The 256-entry xterm palette: 16 ANSI, 216 color cube, 24 grayscale.
    static let palette: [NSColor] = buildPalette()

    private static func buildPalette() -> [NSColor] {
        var colors: [NSColor] = []
        colors.reserveCapacity(256)

        // 0–15: standard + bright ANSI colors (classic xterm RGB triples).
        let ansi: [(Int, Int, Int)] = [
            (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
            (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
            (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
            (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
        ]
        for (r, g, b) in ansi { colors.append(rgb(r, g, b)) }

        // 16–231: 6×6×6 color cube.
        let levels = [0, 95, 135, 175, 215, 255]
        for r in 0..<6 {
            for g in 0..<6 {
                for b in 0..<6 {
                    colors.append(rgb(levels[r], levels[g], levels[b]))
                }
            }
        }

        // 232–255: 24-step grayscale ramp.
        for i in 0..<24 {
            let v = 8 + i * 10
            colors.append(rgb(v, v, v))
        }
        return colors
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}
