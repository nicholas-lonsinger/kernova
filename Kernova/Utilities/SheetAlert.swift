import AppKit

/// Semantic role for an ``AlertButton``.
///
/// Drives the key-equivalent and destructive-tint configuration applied to
/// the corresponding `NSAlert` button.
enum AlertButtonRole {
    /// Activated by the Return key. At most one button per alert should
    /// have this role.
    case `default`
    /// Activated by the Escape key. AppKit also auto-binds Escape when a
    /// button's title is "Cancel", but setting `.cancel` here makes the
    /// intent explicit regardless of title.
    case cancel
    /// Tinted red via `NSButton.hasDestructiveAction`. Not activated by
    /// Return — matches SwiftUI convention where `Button(role: .destructive)`
    /// does not become the default button.
    case destructive
    /// Standard button, no special key equivalent or tinting.
    case standard
}

/// One button in an ``AlertConfiguration``.
///
/// The action closure fires when the user activates the button.
struct AlertButton {
    let title: String
    let role: AlertButtonRole
    let action: () -> Void

    init(_ title: String, role: AlertButtonRole = .standard, action: @escaping () -> Void = {}) {
        self.title = title
        self.role = role
        self.action = action
    }
}

/// Declarative description of a sheet alert.
///
/// Passed to ``presentSheetAlert(_:in:completion:)`` (or the SwiftUI
/// `.sheetAlert(...)` modifier). Buttons appear in `NSAlert` in the order
/// listed; the first button added is the AppKit "default" by convention,
/// but ``presentSheetAlert(_:in:completion:)`` overrides the default
/// key-equivalent based on roles so the user's chosen `.default` (or none
/// at all) is honored.
struct AlertConfiguration {
    let title: String
    let message: String
    let buttons: [AlertButton]

    init(title: String, message: String, buttons: [AlertButton]) {
        self.title = title
        self.message = message
        self.buttons = buttons
    }
}

/// Presents an `NSAlert` as a window-modal sheet on `window`.
///
/// - Parameters:
///   - config: Title, message, and buttons.
///   - window: The window the sheet attaches to. Typically the host view's
///     own `view.window`, captured via the
///     `.sheetAlert(...)` SwiftUI modifier's `WindowAccessor`.
///   - completion: Fired after the user's chosen button action has run.
///     The bridge modifier uses this to reset the SwiftUI `isPresented`
///     binding.
@MainActor
func presentSheetAlert(
    _ config: AlertConfiguration,
    in window: NSWindow,
    completion: (() -> Void)? = nil
) {
    let alert = NSAlert()
    alert.messageText = config.title
    alert.informativeText = config.message

    for button in config.buttons {
        let nsButton = alert.addButton(withTitle: button.title)
        configureNSAlertButton(nsButton, role: button.role)
    }

    // If no button asked for `.default`, clear the auto-Return on the
    // first added button so Return is inert — matches SwiftUI behavior for
    // destructive-only alerts (Force Stop, Delete VM, etc.) where the user
    // must explicitly click.
    if !config.buttons.contains(where: { $0.role == .default }), let first = alert.buttons.first {
        first.keyEquivalent = ""
    }

    alert.beginSheetModal(for: window) { response in
        dispatchAction(for: response, buttons: config.buttons)
        completion?()
    }
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
@MainActor
func dispatchAction(for response: NSApplication.ModalResponse, buttons: [AlertButton]) {
    let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    guard index >= 0, index < buttons.count else { return }
    buttons[index].action()
}
