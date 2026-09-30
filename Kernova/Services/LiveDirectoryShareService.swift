import Foundation
import KernovaLogging

/// Installs a live share swap on the running VM's own session.
@MainActor
final class LiveDirectoryShareService: LiveDirectorySharing {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "LiveDirectoryShareService")

    func install(
        _ share: MacOSDirectoryShare, holding opened: [UUID: ScopedAccess],
        releasing released: Set<UUID>, on instance: VMInstance, for sessionID: UUID
    ) {
        guard instance.liveSessionID == sessionID, let context = instance.sessionContext,
            let session = context.session
        else {
            opened.values.forEach { $0.release() }
            #log(
                Self.logger, .notice,
                "Dropping a share swap for '\(instance.name, privacy: .public)': session \(sessionID, privacy: .public) is no longer live"
            )
            return
        }
        for (id, scope) in opened {
            context.fileAccess.holdAttachmentScope(id: id, scope)
        }
        let fileAccess = context.fileAccess
        session.applyDirectoryShare(share) {
            Task { @MainActor in
                for id in released { fileAccess.releaseAttachmentScope(id: id) }
            }
        }
        #log(
            Self.logger, .notice,
            "Swapped the shares of '\(instance.name, privacy: .public)' to \(share.entries.count, privacy: .public) folder(s)"
        )
    }
}
