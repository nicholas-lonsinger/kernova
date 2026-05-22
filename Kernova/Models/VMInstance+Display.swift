import AppKit
import Foundation

/// Display-layer properties that distinguish preparing, cold-paused ("Suspended"), and live-paused ("Paused") states.
extension VMInstance {
    /// Display name that distinguishes preparing, cold-paused ("Suspended"), and live-paused ("Paused").
    var statusDisplayName: String {
        if let state = preparingState { return state.operation.displayLabel }
        return isColdPaused ? "Suspended" : status.displayName
    }

    /// Display color that distinguishes preparing (orange), cold-paused (orange), and live-paused (yellow).
    var statusDisplayColor: NSColor {
        if isPreparing { return .systemOrange }
        return isColdPaused ? .systemOrange : status.statusColor
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

    /// Agent status to surface in the sidebar accessory, or `nil` to hide
    /// the badge entirely.
    ///
    /// Hidden when:
    /// - The guest can't use the Kernova-bundled agent (Linux installs
    ///   `spice-vdagent` itself).
    /// - macOS install is in progress (no agent yet, by design).
    /// - Status is `.current` — no news is good news.
    /// - Status is `.waiting` and the user has dismissed the install nudge.
    /// - The VM is stopped / cold-paused AND the agent has previously
    ///   connected (`lastSeenAgentVersion != nil`). The watchdog only
    ///   fires while running, so `.expectedMissing` only reaches here for
    ///   live sessions and is always surfaced; suppressing `.waiting` for
    ///   already-installed VMs avoids nagging the user when the agent
    ///   simply isn't connected yet.
    ///
    /// `.waiting` (when not suppressed), `.outdated`, `.unresponsive`,
    /// `.expectedMissing`, and `.connecting` are all surfaced.
    var visibleSidebarAgentStatus: AgentStatus? {
        Self.computeVisibleSidebarAgentStatus(
            guestOS: configuration.guestOS,
            installState: installState,
            agentStatus: agentStatus,
            agentInstallNudgeDismissed: configuration.agentInstallNudgeDismissed,
            lastSeenAgentVersion: configuration.lastSeenAgentVersion,
            isLiveSession: virtualMachine != nil
        )
    }

    /// Pure decision function backing ``visibleSidebarAgentStatus``,
    /// exposed for unit tests so the suppression branches can be exercised
    /// without standing up a VsockControlService and faking its agentStatus.
    static func computeVisibleSidebarAgentStatus(
        guestOS: VMGuestOS,
        installState: MacOSInstallState?,
        agentStatus: AgentStatus,
        agentInstallNudgeDismissed: Bool,
        lastSeenAgentVersion: String?,
        isLiveSession: Bool
    ) -> AgentStatus? {
        guard guestOS == .macOS else { return nil }
        guard installState == nil else { return nil }
        if case .current = agentStatus { return nil }
        if case .waiting = agentStatus, agentInstallNudgeDismissed {
            return nil
        }
        if !isLiveSession,
            case .waiting = agentStatus,
            lastSeenAgentVersion != nil
        {
            return nil
        }
        return agentStatus
    }

    /// `true` when this VM has a `.downloadLatest` install context, a
    /// `.kernovadownload` in-progress bundle at the chosen path, and no
    /// completed IPSW yet at the same path.
    ///
    /// Drives the "Resume Install" label variant.
    var hasResumableInstallDownload: Bool {
        #if arch(arm64)
        guard let context = configuration.installContext,
            context.source == .downloadLatest,
            let destinationURL = context.downloadDestinationURL
        else { return false }
        let bundle = IPSWBundle(url: IPSWService.resumeBundleURL(for: destinationURL))
        return bundle.exists
            && !FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false))
        #else
        return false
        #endif
    }
}
