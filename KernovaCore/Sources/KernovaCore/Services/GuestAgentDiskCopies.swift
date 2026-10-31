import Foundation
import KernovaCommandModel
import KernovaLogging

/// The VM's own copy of the guest-agent installer disk a macOS guest below
/// 12.3 takes over virtio (``GuestAgentDiskDelivery``), in its bundle's
/// ``VMBundleLayout/guestAgentDiskDirectoryURL``.
///
/// A copy is made by the bring-up that attaches it, and removed at every
/// power-off and cold boot (``removeAll(in:)``). A suspend keeps it, so the
/// restore attaches the same bytes the state was saved with — unlike a USB
/// installer disk, which no saved state holds.
package enum GuestAgentDiskCopies {
    /// Clones `source` to `copy`, replacing a file already there in one rename.
    package static func make(of source: URL, at copy: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let directory = copy.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let partial = directory.appending(path: ".\(copy.lastPathComponent).\(UUID().uuidString)")
            try FileManager.default.copyItem(at: source, to: partial)
            guard rename(partial.path(percentEncoded: false), copy.path(percentEncoded: false)) == 0 else {
                let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                discard(partial)
                throw failure
            }
        }.value
    }

    /// Makes the virtio copy `config` attaches when `layout` lacks it, from
    /// what `agents` bundles now. A copy already there is left as it is, so a
    /// restore never reads the shared file.
    package static func ensure(
        for config: VMConfiguration, in layout: VMBundleLayout, agents: BundledGuestAgents
    ) async throws {
        guard GuestAgentDiskDelivery.mode(for: config) == .virtio,
            let disk = try await agents.installerDisk(for: .macOS)
        else { return }
        let copy = layout.guestAgentVirtioDiskURL(of: disk)
        if !FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)) {
            try await make(of: disk, at: copy)
        }
    }

    /// Removes every copy `layout` holds.
    package static func removeAll(in layout: VMBundleLayout) {
        discard(layout.guestAgentDiskDirectoryURL)
    }

    /// Removes the copy at `url`, logging any failure but a missing file.
    static func discard(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
        } catch {
            logger.log(
                .error,
                "Cannot remove the guest agent disk copy \(url.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "GuestAgentDiskCopies")
}
