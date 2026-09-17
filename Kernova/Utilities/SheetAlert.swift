import AppKit
import KernovaKit
import KernovaLogging

/// Semantic role for an ``AlertButton``.
///
/// Drives the key-equivalent and destructive-tint configuration applied to
/// the corresponding `NSAlert` button.
enum AlertButtonRole {
    /// Activated by the Return key. At most one button per alert should
    /// have this role.
    case `default`
    /// Activated by the Escape key, regardless of the button's title.
    case cancel
    /// Tinted red via `NSButton.hasDestructiveAction`, and not activated by
    /// Return.
    case destructive
    /// Standard button, no special key equivalent or tinting.
    case standard
}

/// One button in an ``AlertConfiguration``.
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
/// Buttons are added to `NSAlert` in the order listed, which lays them out
/// right-to-left: the first listed sits on the trailing edge. Each button's
/// role — not its position — decides its key equivalent and tint, so at most one
/// carries `.default` and an alert offering none takes no Return at all.
///
/// A confirmation the core raised is built with ``init(confirming:confirm:alternative:dismiss:)``
/// rather than assembled here; the free-form array is for the alerts that
/// confirm nothing — an acknowledgement, or a question the core never modelled.
struct AlertConfiguration {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "AlertConfiguration")

    let title: String
    let message: String
    let buttons: [AlertButton]
    /// Shown between the message and the buttons; `nil` for a text-only alert.
    let accessoryView: NSView?
    /// The control the sheet opens with keyboard focus in.
    ///
    /// An alert whose accessory view is something to fill in has to name it: an
    /// `NSAlert` puts the focus on its default button otherwise, leaving a sheet
    /// that exists to take typing with nowhere for the first keystroke to land.
    let initialFirstResponder: NSView?

    init(
        title: String, message: String, buttons: [AlertButton], accessoryView: NSView? = nil,
        initialFirstResponder: NSView? = nil
    ) {
        self.title = title
        self.message = message
        self.buttons = buttons
        self.accessoryView = accessoryView
        self.initialFirstResponder = initialFirstResponder
    }

    /// Draws a core confirmation.
    ///
    /// The trailing edge always holds an action, never the dismiss: the first
    /// non-destructive one where the confirmation offers any — it takes Return —
    /// and the destructive confirm where it offers none, which then takes no key
    /// at all. Any further non-destructive action follows as `.standard`, then
    /// the dismiss on Escape, then the destructive actions. So a destructive
    /// button is never Return, a two-button alert reads Cancel then its action,
    /// and a three-button one lays out as AppKit's own Save / Cancel / Don't
    /// Save does, the destructive action on the leading edge.
    init(
        confirming prompt: ConfirmationPrompt,
        confirm: @escaping () -> Void,
        alternative: ((ConfirmationAlternative) -> Void)? = nil,
        dismiss: @escaping () -> Void = {}
    ) {
        if !prompt.alternatives.isEmpty, alternative == nil {
            #log(
                Self.logger, .fault,
                "Confirmation '\(prompt.kind.rawValue, privacy: .public)' offers alternatives with no handler"
            )
            assertionFailure(
                "Confirmation '\(prompt.kind.rawValue)' offers alternatives with no handler")
        }
        var actions: [(title: String, isDestructive: Bool, action: () -> Void)] = [
            (prompt.confirmTitle, prompt.confirmIsDestructive, confirm)
        ]
        actions += prompt.alternatives.map { offered in
            (offered.title, offered.isDestructive, { alternative?(offered) })
        }
        let safe = actions.filter { !$0.isDestructive }
        var destructive = actions.filter(\.isDestructive)

        var buttons: [AlertButton] = []
        if safe.isEmpty {
            let leading = destructive.removeFirst()
            buttons.append(
                AlertButton(leading.title, role: .destructive, action: leading.action))
        } else {
            for action in safe {
                buttons.append(
                    AlertButton(
                        action.title, role: buttons.isEmpty ? .default : .standard,
                        action: action.action))
            }
        }
        buttons.append(AlertButton(prompt.dismissTitle, role: .cancel, action: dismiss))
        buttons += destructive.map {
            AlertButton($0.title, role: .destructive, action: $0.action)
        }

        self.init(title: prompt.title, message: prompt.message, buttons: buttons)
    }

    /// An alert that states something and is dismissed, with nothing to decide.
    ///
    /// Return is the standard key for acknowledging one, so its lone button
    /// takes `.default`.
    static func acknowledgement(
        title: String, message: String, accessoryView: NSView? = nil
    ) -> AlertConfiguration {
        AlertConfiguration(
            title: title, message: message, buttons: [AlertButton("OK", role: .default)],
            accessoryView: accessoryView)
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
    _ config: AlertConfiguration,
    in window: NSWindow,
    didDismiss: (() -> Void)? = nil,
    completion: (() -> Void)? = nil
) -> NSAlert {
    assert(
        config.buttons.filter { $0.role == .default }.count <= 1,
        "An alert takes at most one Return key: '\(config.title)'")

    let alert = NSAlert()
    alert.messageText = config.title
    alert.informativeText = config.message
    alert.accessoryView = config.accessoryView

    for button in config.buttons {
        let nsButton = alert.addButton(withTitle: button.title)
        configureNSAlertButton(nsButton, role: button.role)
    }

    // After the buttons, so the alert's window is built from the finished
    // layout — reading `alert.window` is what creates it.
    if let responder = config.initialFirstResponder {
        alert.window.initialFirstResponder = responder
    }

    let dismissal = makeSheetAlertDismissal(
        buttons: config.buttons, didDismiss: didDismiss, completion: completion)
    alert.beginSheetModal(for: window) { response in
        dismissal(response)
    }
    return alert
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
/// ended the sheet — `DetailAlertsPresenter.stop()` for a window going away —
/// rather than from a guess made here about what a framework response meant.
@MainActor
func dispatchAction(for response: NSApplication.ModalResponse, buttons: [AlertButton]) {
    let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    guard index >= 0, index < buttons.count else { return }
    buttons[index].action()
}
