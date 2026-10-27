import AppKit

/// A radio button whose double-click sends ``doubleAction`` to its target in
/// place of the second click's action, so the double action makes the choice
/// itself.
///
/// Only a click count of exactly 2 sends it: a third click lands on whatever
/// the double action put in the button's place and stays a plain click there.
@MainActor
final class DoubleClickRadioButton: NSButton {
    var doubleAction: Selector?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, isEnabled, let doubleAction {
            sendAction(doubleAction, to: target)
        } else {
            super.mouseDown(with: event)
        }
    }
}
