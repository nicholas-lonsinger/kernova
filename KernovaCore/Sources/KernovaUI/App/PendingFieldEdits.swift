import AppKit

/// The text edits open in windows.
@MainActor
enum PendingFieldEdits {
    /// Ends the edit in each of `windows` whose first responder is a field
    /// editor, which commits it through the field's own end-edit — the path Tab
    /// or a click into another field takes.
    ///
    /// Every window rather than the key one: a status-item menu acts while the
    /// library window keeps its field editor without being key. A text view
    /// that is not a field editor — a note, the guest display — keeps focus.
    static func save(in windows: [NSWindow]) {
        for window in windows {
            guard let editor = window.firstResponder as? NSText, editor.isFieldEditor else { continue }
            window.makeFirstResponder(nil)
        }
    }
}
