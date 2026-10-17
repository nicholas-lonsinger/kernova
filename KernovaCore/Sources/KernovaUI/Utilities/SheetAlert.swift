import AppKit
import KernovaCore

/// An ``AlertConfiguration`` with the view drawn between its message and its
/// buttons.
///
/// Reads through to the configuration it draws, so `alert.buttons` is that
/// configuration's buttons.
@dynamicMemberLookup
struct SheetAlert {
    let configuration: AlertConfiguration
    /// Shown between the message and the buttons; `nil` for a text-only alert.
    let accessoryView: NSView?
    /// The control the sheet opens with keyboard focus in.
    ///
    /// An alert whose accessory view is something to fill in has to name it: an
    /// `NSAlert` puts the focus on its default button otherwise, leaving a sheet
    /// that exists to take typing with nowhere for the first keystroke to land.
    let initialFirstResponder: NSView?

    init(
        _ configuration: AlertConfiguration, accessoryView: NSView? = nil,
        initialFirstResponder: NSView? = nil
    ) {
        self.configuration = configuration
        self.accessoryView = accessoryView
        self.initialFirstResponder = initialFirstResponder
    }

    subscript<Value>(dynamicMember keyPath: KeyPath<AlertConfiguration, Value>) -> Value {
        configuration[keyPath: keyPath]
    }
}

/// What a sheet alert's dismissal does, in the order its callers' state
/// machines depend on.
///
/// `didDismiss` runs first because the sheet is already off screen by then:
/// state meaning *an alert is up* has to be clear before the chosen button's
/// action, or an action that puts up its own alert is refused by the flag its
/// own dismissal is about to drop. `completion` runs last, once the action has
/// had its turn — which is what lets a queue drain into the slot the action did
/// not take.
@MainActor
func makeSheetAlertDismissal(
    buttons: [AlertButton], didDismiss: (() -> Void)?, completion: (() -> Void)?
) -> @MainActor (NSApplication.ModalResponse) -> Void {
    { response in
        didDismiss?()
        dispatchAction(for: response, buttons: buttons)
        completion?()
    }
}

/// Presents an `NSAlert` as a window-modal sheet on `window`, answering with
/// the alert it put up — what a caller ending the sheet itself passes to
/// `endSheet(_:returnCode:)`.
///
/// The two hooks fire either side of the chosen button's action — see
/// ``makeSheetAlertDismissal(buttons:didDismiss:completion:)``.
@MainActor
@discardableResult
func presentSheetAlert(
    _ sheet: SheetAlert,
    in window: NSWindow,
    didDismiss: (() -> Void)? = nil,
    completion: (() -> Void)? = nil
) -> NSAlert {
    assert(
        sheet.buttons.filter { $0.role == .default }.count <= 1,
        "An alert takes at most one Return key: '\(sheet.title)'")

    let alert = NSAlert()
    alert.messageText = sheet.title
    alert.informativeText = sheet.message
    alert.accessoryView = sheet.accessoryView

    for button in sheet.buttons {
        let nsButton = alert.addButton(withTitle: button.title)
        configureNSAlertButton(nsButton, role: button.role)
    }

    // After the buttons, so the alert's window is built from the finished
    // layout — reading `alert.window` is what creates it.
    if let responder = sheet.initialFirstResponder {
        alert.window.initialFirstResponder = responder
    }

    let dismissal = makeSheetAlertDismissal(
        buttons: sheet.buttons, didDismiss: didDismiss, completion: completion)
    alert.beginSheetModal(for: window) { response in
        dismissal(response)
    }
    return alert
}

/// ``presentSheetAlert(_:in:didDismiss:completion:)`` for an alert with no
/// accessory view.
@MainActor
@discardableResult
func presentSheetAlert(
    _ config: AlertConfiguration,
    in window: NSWindow,
    didDismiss: (() -> Void)? = nil,
    completion: (() -> Void)? = nil
) -> NSAlert {
    presentSheetAlert(SheetAlert(config), in: window, didDismiss: didDismiss, completion: completion)
}

/// Applies the key-equivalent and destructive tint for a role to an
/// `NSAlert`-managed `NSButton`.
@MainActor
func configureNSAlertButton(_ button: NSButton, role: AlertButtonRole) {
    switch role {
    case .default:
        button.keyEquivalent = "\r"
    case .cancel:
        button.keyEquivalent = "\u{1B}"
    case .destructive:
        button.keyEquivalent = ""
        button.hasDestructiveAction = true
    case .standard:
        button.keyEquivalent = ""
    }
}

/// Maps an `NSAlert` modal response to the corresponding ``AlertButton``
/// and fires its action.
///
/// Responses are zero-indexed from `.alertFirstButtonReturn` (1000), so
/// `response.rawValue - 1000` is the index of the button the user picked.
///
/// A response naming no button ran no action, because nothing was chosen. An
/// alert whose answer something is waiting on gets that answer from whatever
/// ended the sheet — `AppAlertPresenter` for a window going away —
/// rather than from a guess made here about what a framework response meant.
@MainActor
func dispatchAction(for response: NSApplication.ModalResponse, buttons: [AlertButton]) {
    let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    guard index >= 0, index < buttons.count else { return }
    buttons[index].action()
}
