import Foundation
import KernovaAgentCore
import KernovaCommandModel

/// A graceful stop the guest's agents took that did not take the guest down,
/// or one Kernova can't tell the fate of.
struct GuestShutdownNotCarriedOut: LocalizedError, TitledError, Equatable {
    /// How the shutdown ended.
    enum Reason: Equatable {
        /// These apps stopped it. `skippable` when an agent can shut the guest
        /// down without waiting for them, which only the caller's consent asks.
        case blocked([AppValue], skippable: Bool)
        /// A user in the guest cancelled it.
        case cancelledInGuest
        /// The guest's OS gave up after taking it.
        case failed(WireError)
        /// Kernova can't tell whether the guest is going down.
        case indeterminate
    }

    let vmName: String
    let reason: Reason

    var alertTitle: String? {
        switch reason {
        case .blocked, .cancelledInGuest, .failed: "\u{201C}\(vmName)\u{201D} Didn\u{2019}t Shut Down"
        case .indeterminate: nil
        }
    }

    var errorDescription: String? {
        switch reason {
        case .blocked(let apps, _):
            Self.blockers(apps)
                + " To shut it down anyway, use Force Stop, which loses any unsaved data inside the guest."
        case .cancelledInGuest:
            "Shutting down was cancelled inside \u{201C}\(vmName)\u{201D}."
        case .failed(let error):
            "\u{201C}\(vmName)\u{201D} couldn\u{2019}t shut down"
                + (error.posixErrno == 0 ? "" : ": \(String(cString: strerror(error.posixErrno)))") + "."
        case .indeterminate:
            "Kernova can\u{2019}t tell whether \u{201C}\(vmName)\u{201D} is shutting down. "
                + "If it doesn\u{2019}t stop, use Force Stop."
        }
    }

    /// The question a shutdown an agent can carry out past the apps that
    /// blocked it asks first, worded for a Restart's when `restarting`; `nil`
    /// for every other way a shutdown did not happen.
    ///
    /// systemd documents what skipping the apps' inhibitor locks does
    /// (systemctl(1), `--ignore-inhibitors`): the shutdown runs as any other,
    /// without waiting for them, and nothing asks them to save.
    func skipBlockingAppsPrompt(restarting: Bool) -> ConfirmationPrompt? {
        guard case .blocked(let apps, skippable: true) = reason else { return nil }
        let name = "\u{201C}\(vmName)\u{201D}"
        let blockers = Self.blockers(apps)
        let closing = "but the apps blocking it close without being asked to save."
        return restarting
            ? ConfirmationPrompt(
                kind: .skipBlockingApps, title: "\(name) Didn\u{2019}t Restart",
                message:
                    "\(blockers) If you restart it anyway, the guest\u{2019}s services stop and its disks unmount "
                    + "as in any restart, \(closing)",
                confirmTitle: "Restart Anyway", dismissTitle: "Cancel")
            : ConfirmationPrompt(
                kind: .skipBlockingApps, title: "\(name) Didn\u{2019}t Shut Down",
                message:
                    "\(blockers) If you shut it down anyway, the guest\u{2019}s services stop and its disks unmount "
                    + "as in any shutdown, \(closing)",
                confirmTitle: "Shut Down Anyway", dismissTitle: "Cancel")
    }

    /// The sentence naming the apps that blocked the shutdown.
    private static func blockers(_ apps: [AppValue]) -> String {
        let names = apps.map(\.shownName).filter { !$0.isEmpty }
        guard !names.isEmpty else { return "An app is blocking it." }
        let list = ListFormatter.localizedString(byJoining: names)
        return "\(list) \(names.count == 1 ? "is" : "are") blocking it."
    }
}

extension AppValue {
    /// The name the UI shows for the app: its display name, else its
    /// identifier, since the guest may send either empty.
    var shownName: String { displayName.isEmpty ? identifier : displayName }
}
