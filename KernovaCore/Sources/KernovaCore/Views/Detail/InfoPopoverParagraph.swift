import Foundation

/// One paragraph rendered inside an `InfoPopoverContentViewController`.
package enum InfoPopoverParagraph: Equatable {
    /// A message's title in the callout headline style, for a popover that
    /// shows a message the way the user meets it.
    case headline(String)
    /// Wrapping body text in the shared `.callout` style, in which a
    /// backtick-delimited span renders in `CalloutStyle.codeFont` without
    /// its backticks.
    case body(String)
    /// Monospaced, selectable text for shell commands and similar
    /// copy-worthy snippets.
    case code(String)

    /// The message titled `title` reading `text`, as the user meets it.
    package static func message(title: String, text: String?) -> [InfoPopoverParagraph] {
        [.headline(title)] + (text.map { [.body($0)] } ?? [])
    }
}
