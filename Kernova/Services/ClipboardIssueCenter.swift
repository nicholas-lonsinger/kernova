import Foundation
import Observation
import os

/// App-level aggregate, keyed by VM, of each one's outstanding clipboard
/// transfer problem.
///
/// Clipboard services are per-VM and their window is optional, so a refusal
/// raised while no window is open has nowhere to render. Every service reports
/// here instead, and this is the only record — a service superseded by a
/// reconnect still raises the failures of the pasteboard promises it published,
/// so a problem outlives the connection that raised it and cannot be kept on one.
///
/// ``latestByInstance`` feeds the clipboard window's banner and the menu-bar
/// dropdown's per-VM lines; ``pendingNotice`` carries the one refusal no open
/// window is already showing, for a surface that can interrupt.
@MainActor
@Observable
final class ClipboardIssueCenter {
    /// The process-wide center every clipboard service reports to by default.
    static let shared = ClipboardIssueCenter()

    private static let logger = Logger(subsystem: "app.kernova", category: "ClipboardIssueCenter")

    /// One VM's outstanding clipboard problem, with everything a surface needs to
    /// render it without reaching back to the instance.
    struct Notice: Equatable, Sendable {
        let instanceID: UUID
        let vmName: String
        let issue: ClipboardTransferIssue
        /// The paste ceiling in force when the issue was raised, so a ceiling
        /// changed afterwards cannot rewrite the figure this message names.
        let pasteLimitBytes: Int
    }

    /// The outstanding problem of each VM that has one.
    private(set) var latestByInstance: [UUID: Notice] = [:]

    /// The problem awaiting an interrupting surface, or `nil` when none is.
    ///
    /// Set only for a VM nobody is watching, and only for an issue whose gesture
    /// was made on this Mac (`ClipboardTransferIssue.warrantsInterruptingNotice`):
    /// a clipboard window on screen renders the issue itself, and a second
    /// surface for the same news would be noise.
    private(set) var pendingNotice: Notice?

    /// VMs whose clipboard window is on screen and rendering
    /// ``latestByInstance`` itself.
    @ObservationIgnored
    private var watchedInstances: Set<UUID> = []

    /// Records `issue` as the VM's outstanding problem, and offers it to the
    /// interrupting surface unless the VM is being watched or the refusal is the
    /// guest's own to report.
    func report(
        _ issue: ClipboardTransferIssue, instanceID: UUID, vmName: String, pasteLimitBytes: Int
    ) {
        let notice = Notice(
            instanceID: instanceID, vmName: vmName, issue: issue, pasteLimitBytes: pasteLimitBytes)
        latestByInstance[instanceID] = notice
        guard issue.warrantsInterruptingNotice else {
            Self.logger.debug(
                "Clipboard issue recorded for '\(vmName, privacy: .public)' — the guest reports its own refusal"
            )
            return
        }
        guard !watchedInstances.contains(instanceID) else {
            Self.logger.debug(
                "Clipboard issue recorded for watched VM '\(vmName, privacy: .public)' — its window renders it"
            )
            return
        }
        pendingNotice = notice
        Self.logger.notice(
            "Clipboard issue pending a menu-bar notice for '\(vmName, privacy: .public)': \(issue.menuLineText, privacy: .public)"
        )
    }

    /// Drops the VM's outstanding problem, and the pending notice when it was
    /// that VM's.
    func clear(instanceID: UUID) {
        latestByInstance.removeValue(forKey: instanceID)
        if pendingNotice?.instanceID == instanceID { pendingNotice = nil }
    }

    /// Takes the pending notice off the queue once a surface has presented it (or
    /// declined to).
    func consumePendingNotice() {
        pendingNotice = nil
    }

    /// Marks the VM as rendering its own issues, retiring any notice queued for
    /// it.
    func beginWatching(instanceID: UUID) {
        watchedInstances.insert(instanceID)
        if pendingNotice?.instanceID == instanceID { pendingNotice = nil }
    }

    /// Marks the VM as no longer rendering its own issues.
    ///
    /// Issues raised while it was watched stay consumed — only a problem raised
    /// after this queues a notice.
    func endWatching(instanceID: UUID) {
        watchedInstances.remove(instanceID)
    }
}
