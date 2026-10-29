import Foundation
import KernovaCommandModel
import KernovaLogging

/// The VM's own copies of guest-agent installer disks, in its bundle's
/// ``VMBundleLayout/guestAgentDiskDirectoryURL``.
///
/// A copy is made when its disk is attached, and removed with the entry that
/// attached it (``removeCopies(droppedFrom:to:in:)``, which every committed
/// configuration change runs) and at every power-off and cold boot
/// (``removeAll(in:)``). A suspend keeps it, so the restore attaches the same
/// bytes the state was saved with.
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

    /// Makes each copy `config` attaches that `layout` lacks, from what
    /// `agents` bundles now: an installer entry naming this build's own file,
    /// and the virtio DMG of a macOS guest below 12.3. A copy already there is
    /// left as it is, so a restore never reads the shared file.
    package static func ensure(
        for config: VMConfiguration, in layout: VMBundleLayout, agents: BundledGuestAgents
    ) async throws {
        for item in config.removableMedia ?? []
        where item.installerCopy(in: layout) == nil && agents.isInstallerDisk(path: item.path) {
            guard let disk = try await agents.installerDisk(for: config.guestOS) else { continue }
            try await make(of: disk, at: layout.guestAgentDiskCopyURL(for: item))
        }
        if GuestAgentDiskDelivery.mode(for: config) == .virtio,
            let disk = try await agents.installerDisk(for: .macOS)
        {
            let copy = layout.guestAgentVirtioDiskURL(of: disk)
            if !FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)) {
                try await make(of: disk, at: copy)
            }
        }
    }

    /// Removes the copy of every entry `old` lists and `new` does not — the
    /// one place a dropped installer entry takes its copy — and the directory
    /// once it holds none. A guest still attached to a copy keeps its handle
    /// until the reconcile detaches it.
    static func removeCopies(droppedFrom old: VMConfiguration, to new: VMConfiguration, in layout: VMBundleLayout) {
        let kept = Set((new.removableMedia ?? []).map(\.id))
        var removed = false
        for item in old.removableMedia ?? [] where !kept.contains(item.id) {
            guard let copy = item.installerCopy(in: layout) else { continue }
            discard(copy)
            removed = true
        }
        guard removed else { return }
        // rmdir removes only an empty directory, so a copy still there keeps it.
        let directory = layout.guestAgentDiskDirectoryURL.path(percentEncoded: false)
        if rmdir(directory) != 0, errno != ENOTEMPTY, errno != EEXIST, errno != ENOENT {
            logger.log(
                .error,
                "Cannot remove the guest agent disk directory \(directory, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)"
            )
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
