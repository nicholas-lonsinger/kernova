import Foundation

/// One paragraph rendered inside an ``InfoPopoverContentViewController``.
enum InfoPopoverParagraph: Equatable {
    /// Wrapping body text in the shared `.callout` style, in which a
    /// backtick-delimited span renders in ``CalloutStyle/codeFont`` without
    /// its backticks.
    case body(String)
    /// Monospaced, selectable text for shell commands and similar
    /// copy-worthy snippets.
    case code(String)
}
