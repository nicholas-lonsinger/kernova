import Foundation
import KernovaLogging

/// Installs a live share swap on a running macOS guest's directory-sharing
/// device.
@MainActor
final class LiveDirectoryShareService {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "LiveDirectoryShareService")

    /// Sets the share the device of `swap`'s session carries to `swap.share`:
    /// `opened` — the scopes of the folders in ``LiveShareSwap/held`` — joins
    /// what that session holds, and the scope of each shared directory in
    /// ``LiveShareSwap/released`` is let go once the device no longer carries it.
    ///
    /// When the swap's session is no longer the live one, `opened` is released
    /// and nothing else happens.
    func install(_ swap: LiveShareSwap, holding opened: [UUID: ScopedAccess], on instance: VMInstance) {
        let sessionID = swap.sessionID
        guard instance.liveSessionID == sessionID, let context = instance.sessionContext,
            let session = context.session
        else {
            opened.values.forEach { $0.release() }
            Self.logger.log(
                .notice,
                "Dropping a share swap for '\(instance.name, privacy: .public)': session \(sessionID, privacy: .public) is no longer live"
            )
            return
        }
        for (id, scope) in opened {
            context.fileAccess.holdAttachmentScope(id: id, scope)
        }
        let fileAccess = context.fileAccess
        session.applyDirectoryShare(swap.share) {
            Task { @MainActor in
                for id in swap.released { fileAccess.releaseAttachmentScope(id: id) }
            }
        }
        Self.logger.log(
            .notice,
            "Swapped the shares of '\(instance.name, privacy: .public)' to \(swap.share.entries.count, privacy: .public) folder(s)"
        )
    }
}

/// A running macOS guest's directory-sharing device, as a live share edit
/// finds it.
struct LiveShareDevice: Equatable {
    /// The session whose device this is.
    let sessionID: UUID
    /// The share the device carries now.
    let serving: MacOSDirectoryShare

    /// The device of `instance`'s live session; `nil` when no live session
    /// carries a share.
    @MainActor
    init?(of instance: VMInstance) {
        guard let sessionID = instance.liveSessionID,
            let serving = instance.sessionContext?.directoryShare
        else { return nil }
        self.sessionID = sessionID
        self.serving = serving
    }

    /// The swap that moves this device from what it serves to `share`.
    func swap(to share: MacOSDirectoryShare) -> LiveShareSwap {
        let served = Set(serving.entries.map(\.id))
        let shared = Set(share.entries.map(\.id))
        return LiveShareSwap(
            sessionID: sessionID, share: share,
            held: shared.subtracting(served), released: served.subtracting(shared))
    }
}

/// One live share swap: the share a session's device carries next, and whose
/// security scopes change hands with it.
struct LiveShareSwap: Equatable {
    /// The session whose device takes the swap.
    let sessionID: UUID
    /// The share the device carries after the swap.
    let share: MacOSDirectoryShare
    /// The shares the device newly carries, whose scopes the session takes.
    let held: Set<UUID>
    /// The shares the device stops carrying, whose scopes the session lets go.
    let released: Set<UUID>
}
