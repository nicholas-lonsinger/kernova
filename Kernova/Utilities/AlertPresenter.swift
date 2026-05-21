import AppKit

/// Role classification for a button in an ``AlertPresenter`` alert.
///
/// The role drives two things:
/// * key-equivalent assignment — `.default` and `.destructive` bind Return,
///   `.cancel` binds Escape, `.plain` is keyboard-inert,
/// * `NSButton.hasDestructiveAction` — only `.destructive` flips this on,
///   which renders the button in the system's destructive style.
///
/// Multiple roles may appear in one alert (e.g. a three-button "Move to Trash
/// / Remove from VM / Cancel" prompt with one `.destructive`, one `.default`
/// and one `.cancel`). Only the first `.default` or `.destructive` button
/// added gets Return — NSAlert binds Return to the first added button only.
enum AlertButtonRole: Sendable {
    case `default`
    case cancel
    case destructive
    case plain
}

/// Declarative description of a button in an ``AlertPresenter`` alert.
///
/// The completion handler returns the *index* of the chosen button into the
/// array passed to ``AlertPresenter/present(in:title:message:style:buttons:completion:)``,
/// not a raw `NSApplication.ModalResponse`, so call sites can switch on a
/// small integer without translating modal-response constants every time.
struct AlertButton: Sendable {
    let title: String
    let role: AlertButtonRole

    init(title: String, role: AlertButtonRole = .plain) {
        self.title = title
        self.role = role
    }

    static func `default`(_ title: String) -> AlertButton {
        AlertButton(title: title, role: .default)
    }

    static func ok(_ title: String = "OK") -> AlertButton {
        AlertButton(title: title, role: .default)
    }

    static func cancel(_ title: String = "Cancel") -> AlertButton {
        AlertButton(title: title, role: .cancel)
    }

    static func destructive(_ title: String) -> AlertButton {
        AlertButton(title: title, role: .destructive)
    }

    static func plain(_ title: String) -> AlertButton {
        AlertButton(title: title, role: .plain)
    }
}

/// Sheet-modal `NSAlert` helper.
///
/// Replaces SwiftUI's `.alert()` modifier in pure-AppKit view controllers.
/// Always presents as a sheet (`beginSheetModal(for:completionHandler:)`),
/// never `runModal()` — `runModal` blocks the main run loop, which interferes
/// with `withObservationTracking`-based observation loops the rest of the UI
/// depends on.
///
/// All entry points are `@MainActor`-isolated; completion handlers also run
/// on the main actor.
@MainActor
enum AlertPresenter {
    /// Presents an alert as a sheet attached to `window` and reports the
    /// user's choice by index into `buttons`.
    ///
    /// The completion handler receives an `Int` in `0..<buttons.count`
    /// matching the index of the chosen button. If `buttons` is empty,
    /// an OK button is added automatically so the alert is dismissable;
    /// the completion fires with index `0`.
    static func present(
        in window: NSWindow,
        title: String,
        message: String,
        style: NSAlert.Style = .warning,
        buttons: [AlertButton],
        completion: @escaping @MainActor (Int) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style

        let effectiveButtons = buttons.isEmpty ? [AlertButton.ok()] : buttons
        for descriptor in effectiveButtons {
            let nsButton = alert.addButton(withTitle: descriptor.title)
            switch descriptor.role {
            case .default:
                // First-added button already gets `\r` from NSAlert; setting
                // it explicitly is idempotent and makes intent visible.
                nsButton.keyEquivalent = "\r"
            case .cancel:
                nsButton.keyEquivalent = "\u{1B}"
            case .destructive:
                nsButton.keyEquivalent = "\r"
                nsButton.hasDestructiveAction = true
            case .plain:
                nsButton.keyEquivalent = ""
            }
        }

        alert.beginSheetModal(for: window) { response in
            // `beginSheetModal` invokes its completion handler on the main
            // thread but does not annotate the closure as `@MainActor`, so
            // Swift 6 strict concurrency requires an explicit hop.
            let index = Self.buttonIndex(for: response, count: effectiveButtons.count)
            MainActor.assumeIsolated {
                completion(index)
            }
        }
    }

    /// Convenience for informational alerts with a single OK button.
    static func info(
        in window: NSWindow,
        title: String,
        message: String,
        style: NSAlert.Style = .informational,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        present(
            in: window,
            title: title,
            message: message,
            style: style,
            buttons: [.ok()]
        ) { _ in
            completion()
        }
    }

    /// Maps an `NSApplication.ModalResponse` from `NSAlert` back to a
    /// zero-based button index.
    ///
    /// Exposed `internal` so tests can verify the mapping without needing a
    /// live `NSAlert` sheet.
    static func buttonIndex(
        for response: NSApplication.ModalResponse,
        count: Int
    ) -> Int {
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let index = response.rawValue - first
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }
}
