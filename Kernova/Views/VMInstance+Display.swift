import AppKit
import KernovaKit

/// Whether the VM display takes files dragged onto it, and if not, why.
enum DisplayDropAvailability {
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

/// Display-layer properties derived from a VM's status.
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
    var displayDropAvailability: DisplayDropAvailability {
        guard configuration.guestOS == .macOS, configuration.dropFilesEnabled,
            configuration.lastSeenAgentVersion != nil
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
    func sendDroppedFilesToGuest(_ urls: [URL]) -> Bool {
        guard displayDropAvailability == .available, let service = vsockDropService else {
            return false
        }
        return service.startDrop(urls: urls)
    }

    /// Reports a drag the display took that produced no file to send — a file
    /// promise the source failed to write.
    func reportUnreadableDropToGuest() {
        vsockDropService?.reportUnreadableDrop()
    }

    /// Display name that distinguishes preparing, cold-paused ("Suspended"), and live-paused ("Paused").
    var statusDisplayName: String {
        if let state = preparingState { return state.displayLabel }
        return isColdPaused ? "Suspended" : status.displayName
    }

    /// Color used to tint the sidebar's OS icon.
    ///
    /// Preparing, cold-paused, and running-while-awaiting-network-reattach are
    /// orange, live-paused is yellow, and the remaining states follow `status`.
    var statusDisplayNSColor: NSColor {
        if isPreparing || isColdPaused { return StatusColor.warning }
        if status == .running && networkAttachmentPending { return StatusColor.warning }
        switch status {
        // A concrete gray (not `.secondaryLabelColor`) so the icon keeps its
        // stopped color on the selection highlight instead of inverting to white.
        case .stopped: return .systemGray
        case .starting, .saving, .restoring, .installing, .initialBoot: return StatusColor.warning
        case .running: return StatusColor.running
        case .paused: return StatusColor.pausedInMemory
        case .error: return StatusColor.error
        }
    }

    /// The guest-reported OS version for display, or `nil` when no agent has
    /// vouched for one and there is nothing to show.
    ///
    /// What an agent reports is peer-supplied, so it is read through
    /// `KernovaOSVersion.numericVersion(in:)` rather than shown raw.
    var guestOSVersionDisplay: String? {
        guard let reported = configuration.lastSeenGuestOSVersion, !reported.isEmpty else {
            return nil
        }
        return KernovaOSVersion.numericVersion(in: reported) ?? reported
    }

    /// Tooltip explaining the VM state variant, or `nil` for standard states.
    var statusToolTip: String? {
        if let state = preparingState { return state.displayLabel }
        if status == .initialBoot { return "Click Start to install macOS" }
        if status == .error { return errorMessage }
        if status == .running, networkAttachmentPending {
            // Shared and Host Only wait on the app's own network, not a host
            // interface — pointing the user at Wi-Fi/Ethernet would misdirect
            // them.
            return switch configuration.networkMode {
            case .hostOnly:
                "The Host Only network is unavailable. Kernova reconnects automatically."
            case .shared:
                "The Shared Network is unavailable. Kernova reconnects automatically."
            case .bridged:
                "The network interface is unavailable. Kernova reconnects automatically when one is available."
            }
        }
        guard status == .paused else { return nil }
        return isColdPaused
            ? "VM state is saved to disk"
            : "VM is paused in memory"
    }

    /// The flavor of the Start control for this VM: setup-flavored when a macOS
    /// install or a Linux image download is pending, reflecting what Start will
    /// actually do.
    enum StartAction {
        case start
        case install
        case resumeInstall
        case download
        case resumeDownload

        var label: String {
            switch self {
            case .start: "Start"
            case .install: "Install"
            case .resumeInstall: "Resume Install"
            case .download: "Download"
            case .resumeDownload: "Resume Download"
            }
        }
    }

    /// The action the Start control performs for this VM's current setup state.
    var startAction: StartAction {
        if configuration.installContext != nil {
            return hasResumableInstallDownload ? .resumeInstall : .install
        }
        if configuration.linuxInstallContext != nil {
            return hasResumableInstallDownload ? .resumeDownload : .download
        }
        return .start
    }

    /// Menu item title for the stop slot.
    ///
    /// A cold-paused VM has no live `VZVirtualMachine` to stop gracefully — the
    /// action discards the on-disk saved state instead, and the title names that
    /// consequence; the ellipsis is there because the discard variant confirms.
    var stopActionMenuTitle: String {
        isColdPaused ? "Discard Saved State…" : "Stop"
    }

    /// Toolbar label for the stop segment — same wording as `stopActionMenuTitle`
    /// without the trailing ellipsis, which is a menu-only convention.
    var stopActionToolbarLabel: String {
        isColdPaused ? "Discard Saved State" : "Stop"
    }

    /// `true` when this VM's pending setup fetches its image, a
    /// `.kernovadownload` bundle still holds partial bytes at the chosen path,
    /// and no completed image sits at that path yet.
    ///
    /// The bytes check (`isResumable` rather than `exists`) keeps a husk left by a
    /// failed disposal from labelling a from-scratch download as a resume.
    var hasResumableInstallDownload: Bool {
        guard let destinationURL = pendingSetupDownloadDestination else { return false }
        let bundle = DownloadBundle(url: DownloadService.resumeBundleURL(for: destinationURL))
        return bundle.isResumable
            && !FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false))
    }

    /// The file a pending setup would download into, or `nil` when this VM's
    /// setup fetches nothing (a local IPSW or ISO, or no setup at all).
    ///
    /// A Linux catalog pick has no destination until its first resolution names
    /// the file; a URL pick names its own and carries one from the moment the VM
    /// is created.
    private var pendingSetupDownloadDestination: URL? {
        if let context = configuration.installContext {
            return context.source.downloadsImage ? context.downloadDestinationURL : nil
        }
        return configuration.linuxInstallContext?.downloadDestinationURL
    }
}
