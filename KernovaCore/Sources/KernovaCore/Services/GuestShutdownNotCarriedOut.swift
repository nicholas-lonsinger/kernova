import Foundation
import KernovaAgentCore

/// A graceful stop the guest's agents took that did not take the guest down,
/// or one Kernova can't tell the fate of.
struct GuestShutdownNotCarriedOut: LocalizedError, TitledError, Equatable {
    /// How the shutdown ended.
    enum Reason: Equatable {
        /// These apps stopped it.
        case blocked([AppValue])
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
        case .blocked(let apps):
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
