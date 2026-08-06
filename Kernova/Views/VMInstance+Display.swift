import AppKit
import KernovaKit

/// Display-layer properties derived from a VM's status.
extension VMInstance {
    /// Display name that distinguishes preparing, cold-paused ("Suspended"), and live-paused ("Paused").
    var statusDisplayName: String {
        if let state = preparingState { return state.displayLabel }
        return isColdPaused ? "Suspended" : status.displayName
    }

    /// Color used to tint the sidebar's OS icon.
    ///
    /// Preparing and cold-paused are orange, live-paused is yellow, and the
    /// remaining states follow `status`.
    var statusDisplayNSColor: NSColor {
        if isPreparing || isColdPaused { return StatusColor.warning }
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

    /// The guest-reported OS version for display, or "Unknown" when no agent
    /// has vouched for one.
    ///
    /// What an agent reports is peer-supplied, so it is read through
    /// `KernovaOSVersion.numericVersion(in:)` rather than shown raw.
    var guestOSVersionDisplay: String {
        guard let reported = configuration.lastSeenGuestOSVersion, !reported.isEmpty else {
            return "Unknown"
        }
        return KernovaOSVersion.numericVersion(in: reported) ?? reported
    }

    /// Tooltip explaining the VM state variant, or `nil` for standard states.
    var statusToolTip: String? {
        if let state = preparingState { return state.displayLabel }
        if status == .initialBoot { return "Click Start to install macOS" }
        if status == .error { return errorMessage }
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
    /// A Linux context has no destination until its first resolution names the
    /// file, which is exactly when there is nothing to resume from yet.
    private var pendingSetupDownloadDestination: URL? {
        if let context = configuration.installContext {
            return context.source.downloadsImage ? context.downloadDestinationURL : nil
        }
        return configuration.linuxInstallContext?.downloadDestinationURL
    }
}
