import AppKit

/// Display-layer properties that distinguish preparing, cold-paused ("Suspended"), and live-paused ("Paused") states.
extension VMInstance {
    /// Display name that distinguishes preparing, cold-paused ("Suspended"), and live-paused ("Paused").
    var statusDisplayName: String {
        if let state = preparingState { return state.operation.displayLabel }
        return isColdPaused ? "Suspended" : status.displayName
    }

    /// Color used to tint the pure-AppKit sidebar's OS icon.
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

    /// Tooltip explaining the VM state variant, or `nil` for standard states.
    var statusToolTip: String? {
        if let state = preparingState { return state.operation.displayLabel }
        if status == .initialBoot { return "Click Start to install macOS" }
        guard status == .paused else { return nil }
        return isColdPaused
            ? "VM state is saved to disk"
            : "VM is paused in memory"
    }

    /// The flavor of the Start control for this VM, shared by the menu bar, sidebar
    /// context menu, and toolbar so every surface labels the action identically:
    /// install-flavored when a macOS install is pending, reflecting what Start
    /// will actually do.
    enum StartAction {
        case start
        case install
        case resumeInstall

        var label: String {
            switch self {
            case .start: "Start"
            case .install: "Install"
            case .resumeInstall: "Resume Install"
            }
        }
    }

    /// The action the Start control performs for this VM's current install state.
    var startAction: StartAction {
        guard configuration.installContext != nil else { return .start }
        return hasResumableInstallDownload ? .resumeInstall : .install
    }

    /// Menu item title for the stop slot, shared by the menu bar and sidebar context menu.
    ///
    /// A cold-paused VM has no live `VZVirtualMachine` to stop gracefully — the
    /// action discards the on-disk saved state instead, and the title names that
    /// consequence (with an ellipsis: the discard variant always confirms first).
    var stopActionMenuTitle: String {
        isColdPaused ? "Discard Saved State…" : "Stop"
    }

    /// Toolbar label for the stop segment — same wording as `stopActionMenuTitle`
    /// without the trailing ellipsis, which is a menu-only convention.
    var stopActionToolbarLabel: String {
        isColdPaused ? "Discard Saved State" : "Stop"
    }

    /// `true` when this VM has a `.downloadLatest` install context, a
    /// `.kernovadownload` in-progress bundle at the chosen path, and no
    /// completed IPSW yet at the same path.
    ///
    /// Drives the "Resume Install" label variant.
    var hasResumableInstallDownload: Bool {
        guard let context = configuration.installContext,
            context.source == .downloadLatest,
            let destinationURL = context.downloadDestinationURL
        else { return false }
        let bundle = IPSWBundle(url: IPSWService.resumeBundleURL(for: destinationURL))
        return bundle.exists
            && !FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false))
    }
}
