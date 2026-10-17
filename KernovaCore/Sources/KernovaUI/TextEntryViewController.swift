import AppKit

/// A view holding one text field, which takes focus on request.
final class TextEntryViewController: NSViewController {
    let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 64))
        view.addSubview(field)
        self.view = view
    }

    /// Makes the field its window's first responder; false while the view is
    /// in no window or the window refuses.
    func focusField() -> Bool {
        view.window?.makeFirstResponder(field) ?? false
    }
}
