import Foundation
import KernovaKit

/// Whether the VM display takes files dragged onto it, and if not, why.
package enum DisplayDropAvailability {
    /// This VM has never run a guest agent, or has drag and drop switched off, so
    /// the display is not a drag destination at all — a drag over it behaves as
    /// if Kernova were not there.
    case none
    /// The feature is on and the agent has connected before, but the guest cannot
    /// take a drop now — it is paused or stopped, or the channel is down. The
    /// display takes part in the drag and refuses it, which is what puts the
    /// "not allowed" cursor under the pointer and springs a release back.
    case disconnected
    /// Files dropped now will be sent to the guest.
    case available
}

/// Presentation properties derived from a VM's status, shared by every
/// surface that shows the VM.
extension VMInstance {
    /// Whether files dragged onto this VM's display can be sent to the guest.
    ///
    /// The single read site for the gesture's three states. `.none` is decided
    /// from persisted state (`dropFilesEnabled`, `lastSeenAgentVersion`), so it
    /// survives restarts and a VM that has never had an agent — or has the
    /// feature switched off — never advertises a drop it cannot do; the live
    /// channel decides the rest, so an agent that goes away mid-session
    /// downgrades to a refusal on the next observation tick.
    ///
    /// A VM that is not running refuses too: pausing tears down no vsock, so the
    /// channel stays connected while the guest is frozen and cannot answer.
    package var displayDropAvailability: DisplayDropAvailability {
        guard configuration.guestOS == .macOS, configuration.dropFilesEnabled,
            lastSeenAgentVersion != nil
        else { return .none }
        guard status == .running else { return .disconnected }
        guard let drop = vsockDropService, drop.isConnected,
            vsockControlService?.guestSupportsDropFiles == true
        else { return .disconnected }
        return .available
    }

    /// Sends `urls` to the guest's Downloads folder, reporting whether the drop
    /// was taken up.
    ///
    /// Re-checks availability itself: a drag can outlive the channel it was
    /// started over, and a drop the service can no longer serve must spring back
    /// rather than silently vanish.
    ///
    /// `stagedIn` is where a promise drag wrote its files; the service holds it
    /// until that drop settles, and a refused drop leaves it to the caller.
    package func sendDroppedFilesToGuest(_ urls: [URL], stagedIn stagingDirectory: URL? = nil) -> Bool {
        guard displayDropAvailability == .available, let service = vsockDropService else {
            return false
        }
        return service.startDrop(urls: urls, stagedIn: stagingDirectory)
    }

    /// Reports a drag the display took that produced no file to send — a file
    /// promise the source failed to write.
    package func reportUnreadableDropToGuest() {
        vsockDropService?.reportUnreadableDrop()
    }

    /// What a person reads for this VM's status.
    package var statusDisplayName: String {
        status.displayName(heldByAnotherCopy: heldByAnotherCopy)
    }

    /// The guest-reported OS version for display, or `nil` when no agent has
    /// vouched for one and there is nothing to show.
    ///
    /// What an agent reports is peer-supplied, so it is read through
    /// `KernovaOSVersion.numericVersion(in:)` rather than shown raw.
    package var guestOSVersionDisplay: String? {
        guard let reported = reportedGuestOSVersion, !reported.isEmpty else {
            return nil
        }
        return KernovaOSVersion.numericVersion(in: reported) ?? reported
    }

    /// Tooltip explaining the VM state variant, or `nil` for standard states.
    package var statusToolTip: String? {
        if heldByAnotherCopy { return statusDisplayName + "." }
        if status == .initialBoot { return "Click Start to install macOS" }
        if status == .error { return errorMessage }
        if status == .running, networkAttachmentPending {
            // NAT and Host Only wait on the app's own network, not a host
            // interface — pointing the user at Wi-Fi/Ethernet would misdirect
            // them.
            if let network = configuration.joinedNetwork, !network.isCommon {
                return network.isOwn
                    ? "This VM's isolated network is unavailable. Kernova reconnects automatically."
                    : "This VM's network is unavailable. Kernova reconnects automatically."
            }
            return switch configuration.networkMode {
            case .hostOnly, .nat:
                "The \(configuration.networkMode.title) network is unavailable. Kernova reconnects automatically."
            case .bridged:
                "The network interface is unavailable. Kernova reconnects automatically when one is available."
            }
        }
        return switch status {
        case .paused: "VM is paused in memory"
        case .suspended: "VM state is saved to disk"
        default: nil
        }
    }

    /// What the stop slot — the toolbar segment and the menu item sharing it —
    /// performs for a VM, and the words each surface renders it with.
    ///
    /// Resolved by ``VMCapabilityCatalog/stopAction(for:)`` from what the
    /// catalog answers, so the title, the tooltip and the command the slot
    /// invokes come from one derivation and a VM is never offered a word its
    /// state won't honour.
    package enum StopAction {
        /// A live guest, which takes a graceful shutdown request.
        case stop
        /// No live guest to shut down: the slot deletes the bundle's saved state.
        case discardSavedState
        /// An Ephemeral VM's suspended session, whose discard is a revert to the
        /// baseline — so the slot names the outcome the revert produces rather
        /// than a deletion the VM never performs.
        case revertToBaseline

        /// Menu title; the two confirming variants take the ellipsis.
        package var menuTitle: String {
            switch self {
            case .stop: "Stop"
            case .discardSavedState: "Discard Saved State…"
            case .revertToBaseline: "Revert to Baseline…"
            }
        }

        /// Toolbar label — the menu title without the trailing ellipsis, which
        /// is a menu-only convention.
        package var toolbarLabel: String {
            switch self {
            case .stop: "Stop"
            case .discardSavedState: "Discard Saved State"
            case .revertToBaseline: "Revert to Baseline"
            }
        }

        /// Toolbar tooltip for the slot while it can be invoked.
        package var toolTip: String {
            switch self {
            case .stop: "Stop the virtual machine"
            case .discardSavedState: "Discard the virtual machine's saved state"
            case .revertToBaseline: "Return the virtual machine to its baseline snapshot"
            }
        }
    }
}
