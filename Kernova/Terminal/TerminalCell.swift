import Foundation

/// A single character cell in the terminal grid: one glyph plus its visual rendition.
///
/// Value type so an entire `TerminalBuffer` row is a cheap copy-on-write array.
/// Wide (CJK/emoji) characters are treated as single-cell in v1 — see the
/// terminal emulator's known limitations.
struct TerminalCell: Equatable, Sendable {
    /// The glyph occupying this cell. Defaults to a space.
    var scalar: UnicodeScalar
    /// Foreground (text) color.
    var foreground: TerminalColor
    /// Background (fill) color.
    var background: TerminalColor
    /// Style flags (bold, underline, inverse, …).
    var attributes: CellAttributes

    init(
        scalar: UnicodeScalar = " ",
        foreground: TerminalColor = .default,
        background: TerminalColor = .default,
        attributes: CellAttributes = []
    ) {
        self.scalar = scalar
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
    }

    /// An empty cell: a space with default colors and no attributes.
    static let blank = TerminalCell()
}

// MARK: - Cell Attributes

/// SGR style flags applied to a cell. Packed into a `UInt16` option set.
struct CellAttributes: OptionSet, Equatable, Sendable {
    let rawValue: UInt16
    init(rawValue: UInt16) { self.rawValue = rawValue }

    static let bold = CellAttributes(rawValue: 1 << 0)
    static let dim = CellAttributes(rawValue: 1 << 1)
    static let italic = CellAttributes(rawValue: 1 << 2)
    static let underline = CellAttributes(rawValue: 1 << 3)
    static let blink = CellAttributes(rawValue: 1 << 4)
    static let inverse = CellAttributes(rawValue: 1 << 5)
    static let hidden = CellAttributes(rawValue: 1 << 6)
    static let strikethrough = CellAttributes(rawValue: 1 << 7)
}

// MARK: - Terminal Color

/// A terminal color: the default fg/bg, one of the 256 indexed xterm colors,
/// or a 24-bit truecolor value. The concrete `NSColor` mapping lives in the
/// AppKit render layer (`TerminalTheme`) so this type stays AppKit-free.
enum TerminalColor: Equatable, Sendable {
    /// The terminal's default foreground or background (context-dependent).
    case `default`
    /// An index into the 256-color xterm palette (0–15 ANSI, 16–231 cube, 232–255 grayscale).
    case indexed(UInt8)
    /// A 24-bit truecolor value.
    case rgb(UInt8, UInt8, UInt8)
}
