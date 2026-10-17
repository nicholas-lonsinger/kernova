import Foundation
import KernovaKit
import KernovaLogging

/// Semantic role for an ``AlertButton``: which key, if any, activates it, and
/// whether it is drawn as destructive.
package enum AlertButtonRole {
    /// Activated by the Return key. At most one button per alert should
    /// have this role.
    case `default`
    /// Activated by the Escape key, regardless of the button's title.
    case cancel
    /// Tinted as destructive, and not activated by Return.
    case destructive
    /// Standard button, no special key equivalent or tinting.
    case standard
}

/// One button in an ``AlertConfiguration``.
package struct AlertButton {
    package let title: String
    package let role: AlertButtonRole
    package let action: () -> Void

    package init(_ title: String, role: AlertButtonRole = .standard, action: @escaping () -> Void = {}) {
        self.title = title
        self.role = role
        self.action = action
    }
}

/// Declarative description of a sheet alert: what it says and the buttons it
/// offers.
///
/// Buttons are laid out right-to-left in the order listed: the first listed
/// sits on the trailing edge. Each button's
/// role — not its position — decides its key equivalent and tint, so at most one
/// carries `.default` and an alert offering none takes no Return at all.
///
/// A confirmation the core raised is built with ``init(confirming:confirm:alternative:dismiss:)``
/// rather than assembled here; the free-form array is for the alerts that
/// confirm nothing — an acknowledgement, or a question the core never modelled.
package struct AlertConfiguration {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "AlertConfiguration")

    package let title: String
    package let message: String
    package let buttons: [AlertButton]

    package init(title: String, message: String, buttons: [AlertButton]) {
        self.title = title
        self.message = message
        self.buttons = buttons
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
    package init(
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
        self.init(
            title: prompt.title, message: prompt.message,
            buttons: Self.buttons(actions, dismissTitle: prompt.dismissTitle, dismiss: dismiss))
    }

    /// Draws the routes a step refusal names, each button reading the route
    /// and then the request it ends with, laid out by the rule
    /// ``init(confirming:confirm:alternative:dismiss:)`` states: a route that
    /// discards a saved state never takes Return.
    package init(
        offering requirement: StepRequirement, then verbTitle: String?,
        choose: @escaping (StepRoute) -> Void,
        dismiss: @escaping () -> Void = {}
    ) {
        let actions = requirement.routes.map { route -> (title: String, isDestructive: Bool, action: () -> Void) in
            (
                Self.title(of: route, then: verbTitle), route.discardsSavedState,
                { choose(route) }
            )
        }
        self.init(
            title: requirement.title, message: requirement.message,
            buttons: Self.buttons(actions, dismissTitle: "Cancel", dismiss: dismiss))
    }

    /// `route`'s button: its title, then the request it ends with — a start it
    /// names, or `verbTitle` asked again.
    private static func title(of route: StepRoute, then verbTitle: String?) -> String {
        switch route.ending {
        case .start: "\(route.title) and Start"
        case .refusedVerb: verbTitle.map { "\(route.title) and \($0)" } ?? route.title
        }
    }

    /// `actions` and the dismiss, in the order and roles the two initializers
    /// above describe.
    private static func buttons(
        _ actions: [(title: String, isDestructive: Bool, action: () -> Void)],
        dismissTitle: String, dismiss: @escaping () -> Void
    ) -> [AlertButton] {
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
        buttons.append(AlertButton(dismissTitle, role: .cancel, action: dismiss))
        buttons += destructive.map {
            AlertButton($0.title, role: .destructive, action: $0.action)
        }
        return buttons
    }

    /// An alert that states something and is dismissed, with nothing to decide.
    ///
    /// Return is the standard key for acknowledging one, so its lone button
    /// takes `.default`.
    package static func acknowledgement(title: String, message: String) -> AlertConfiguration {
        AlertConfiguration(title: title, message: message, buttons: [AlertButton("OK", role: .default)])
    }
}
