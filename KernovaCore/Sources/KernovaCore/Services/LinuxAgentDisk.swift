import Foundation
import KernovaCommandModel
import KernovaISO9660
import KernovaLogging
import Synchronization

/// The Linux agent's installer disk: an ISO 9660 image with Rock Ridge holding the bundled `kernova-agent`,
/// `install.sh` and `uninstall.sh` (one script, which acts by the name it runs as), `README.txt` and
/// `LICENSES.txt`.
package enum LinuxAgentDisk {
    /// The volume label: where udisks2 mounts it, `/media/$USER/KERNOVA_AGENT` or
    /// `/run/media/$USER/KERNOVA_AGENT`, and the label Kernova shows for the attachment.
    package static let volumeLabel = "KERNOVA_AGENT"

    /// The command that installs the agent from the mounted disk, wherever the guest mounted it: `findmnt` is
    /// util-linux's, on every systemd distribution. `README.txt` gives the same command.
    package static let installCommand = command("install.sh")

    /// The command that removes it.
    package static let uninstallCommand = command("uninstall.sh")

    /// What the install command needs, as the user reads it before the command.
    package static let installCommandPrecondition = "Once the guest's desktop has mounted the disk, run in a terminal:"

    /// The lines that mount the disk on a guest with no desktop, which mounts nothing on its own, and install
    /// the system service from it: `README.txt` gives the same lines.
    package static let mountAndInstallCommands = [
        "sudo mkdir -p /mnt/kernova-agent",
        "sudo mount -o ro LABEL=\(volumeLabel) /mnt/kernova-agent",
        "sh /mnt/kernova-agent/install.sh --system",
    ]

    private static func command(_ script: String) -> String {
        #"sh "$(findmnt -nro TARGET LABEL=\#(volumeLabel))/\#(script)""#
    }

    /// The date every record on the disk carries: fixed, so the image is a function of its files alone.
    static let date = ISO9660Date(year: 2026, month: 1, day: 1)

    /// The directory KernovaCore bundles the disk's other files in: `agent-disk.sh`, `README.txt` and
    /// `LICENSES.txt`.
    package static let bundledFiles: URL = {
        guard let url = Bundle.module.url(forResource: "LinuxAgentDisk", withExtension: nil) else {
            assertionFailure("LinuxAgentDisk missing from KernovaCore's resources")
            return URL(filePath: "/var/empty/LinuxAgentDisk", directoryHint: .isDirectory)
        }
        return url
    }()

    /// The disk's files: the agent read from `agent` as the writer reaches it, and the others from `files`
    /// (``bundledFiles``).
    static func entries(agent: URL, files: URL) throws -> [ISO9660Entry] {
        let script = try resource("agent-disk.sh", in: files)
        let size = try FileManager.default.attributesOfItem(atPath: agent.path(percentEncoded: false))[.size]
        guard let size = (size as? NSNumber)?.uint64Value else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: agent.path(percentEncoded: false)])
        }
        return [
            ISO9660Entry(name: "install.sh", permissions: 0o755, bytes: script),
            ISO9660Entry(name: "uninstall.sh", permissions: 0o755, bytes: script),
            ISO9660Entry(name: "kernova-agent", permissions: 0o755, size: size) { sink in
                let handle = try FileHandle(forReadingFrom: agent)
                defer { try? handle.close() }
                while let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty {
                    try sink(Array(piece))
                }
            },
            ISO9660Entry(name: "README.txt", permissions: 0o644, bytes: try resource("README.txt", in: files)),
            ISO9660Entry(name: "LICENSES.txt", permissions: 0o644, bytes: try resource("LICENSES.txt", in: files)),
        ]
    }

    /// The bytes of `name` in `files`.
    static func resource(_ name: String, in files: URL) throws -> [UInt8] {
        Array(try Data(contentsOf: files.appending(path: name, directoryHint: .notDirectory)))
    }
}

/// Where the Linux agent's installer disk is written, and the one write per process that makes it.
///
/// The disk is app-internal, inside the container, so it needs no bookmark and goes with `removeItem`. It
/// lives at one path for every build: a VM's removable-media entry names that path, and an entry outlives the
/// app it was written under, so a path that changed with the agent would leave every such entry naming a
/// file that is gone. Each process writes it once, on the first ask, beside its final path and then renamed
/// over it, so a VM that has the previous image open keeps reading that one.
package final class GuestAgentDiskCache: Sendable {
    /// The image's path.
    package let url: URL

    private let made = Mutex<Task<URL, any Error>?>(nil)

    /// The disk's files besides the agent (``LinuxAgentDisk/bundledFiles``).
    private let files: URL

    /// A cache writing its image into `directory`, from the files in `files`.
    package init(directory: URL, files: URL) {
        url = directory.appending(path: "linux-arm64.iso", directoryHint: .notDirectory)
        self.files = files
    }

    /// The one the app uses, beside the VM library in Application Support.
    package static let production = GuestAgentDiskCache(
        directory: URL.applicationSupportDirectory.appending(
            path: "Kernova/GuestAgentDisks", directoryHint: .isDirectory),
        files: LinuxAgentDisk.bundledFiles)

    /// The image holding `agent`, written on this process's first ask, off the caller's actor; a write that
    /// failed is tried again on the next ask.
    func disk(agent: URL) async throws -> URL {
        let task = made.withLock { made in
            if let task = made { return task }
            let url = url
            let files = files
            let task = Task.detached(priority: .utility) { () throws -> URL in
                try Self.write(LinuxAgentDisk.entries(agent: agent, files: files), to: url)
                return url
            }
            made = task
            return task
        }
        do {
            return try await task.value
        } catch {
            made.withLock { if $0 == task { $0 = nil } }
            Self.logger.log(
                .error, "Cannot write the Linux agent disk: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private static func write(_ entries: [ISO9660Entry], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: partial.path(percentEncoded: false), contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path(percentEncoded: false)])
        }
        do {
            let handle = try FileHandle(forWritingTo: partial)
            do {
                var pending = Data()
                let writer = ISO9660Writer(volumeIdentifier: LinuxAgentDisk.volumeLabel, date: LinuxAgentDisk.date)
                try writer.write(entries) {
                    pending.append(contentsOf: $0)
                    if pending.count >= 1 << 20 {
                        try handle.write(contentsOf: pending)
                        pending.removeAll(keepingCapacity: true)
                    }
                }
                try handle.write(contentsOf: pending)
            } catch {
                try? handle.close()
                throw error
            }
            try handle.close()
            guard rename(partial.path(percentEncoded: false), url.path(percentEncoded: false)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        logger.log(.notice, "Wrote the Linux agent disk at \(url.path(percentEncoded: false), privacy: .public)")
    }

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "GuestAgentDiskCache")
}

/// The VM's own copies of guest-agent installer disks, in its bundle's
/// ``VMBundleLayout/guestAgentDiskDirectoryURL``: made when a disk is attached,
/// and removed when it is ejected and when the VM powers off.
package enum GuestAgentDiskCopies {
    /// Clones `source` into `layout`'s copy directory, replacing a copy already there in one rename.
    package static func make(of source: URL, in layout: VMBundleLayout) async throws {
        try await Task.detached(priority: .userInitiated) {
            let directory = layout.guestAgentDiskDirectoryURL
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = layout.guestAgentDiskCopyURL(of: source.path(percentEncoded: false))
            let partial = directory.appending(path: ".\(copy.lastPathComponent).\(UUID().uuidString)")
            try FileManager.default.copyItem(at: source, to: partial)
            guard rename(partial.path(percentEncoded: false), copy.path(percentEncoded: false)) == 0 else {
                let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                try? FileManager.default.removeItem(at: partial)
                throw failure
            }
        }.value
    }

    /// Makes the copy of every disk `config` attaches that `layout` lacks — an
    /// installer entry, and the virtio DMG of a macOS guest below 12.3 — from
    /// what `agents` bundles now.
    package static func ensure(
        for config: VMConfiguration, in layout: VMBundleLayout, agents: BundledGuestAgents
    ) async throws {
        var sources: [VMGuestOS] = []
        if (config.removableMedia ?? []).contains(where: { $0.isInstaller(of: agents) }) {
            sources.append(config.guestOS)
        }
        if GuestAgentDiskDelivery.mode(for: config) == .virtio, agents.bundlesInstallerDisk(for: .macOS) {
            sources.append(.macOS)
        }
        for guestOS in sources {
            guard let disk = try await agents.installerDisk(for: guestOS) else { continue }
            let copy = layout.guestAgentDiskCopyURL(of: disk.path(percentEncoded: false))
            guard !FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)) else { continue }
            try await make(of: disk, in: layout)
        }
    }

    /// Removes the copy of the disk at `sourcePath`; a missing one is skipped.
    package static func remove(of sourcePath: String, in layout: VMBundleLayout) {
        remove(layout.guestAgentDiskCopyURL(of: sourcePath))
    }

    /// Removes every copy `layout` holds.
    package static func removeAll(in layout: VMBundleLayout) {
        remove(layout.guestAgentDiskDirectoryURL)
    }

    private static func remove(_ url: URL) {
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
