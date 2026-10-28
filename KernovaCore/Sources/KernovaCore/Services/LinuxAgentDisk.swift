import Foundation
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

    private static func command(_ script: String) -> String {
        #"sh "$(findmnt -nro TARGET LABEL=\#(volumeLabel))/\#(script)""#
    }

    /// The date every record on the disk carries: fixed, so the image is a function of its files alone.
    static let date = ISO9660Date(year: 2026, month: 1, day: 1)

    /// The disk's files, the agent read from `agent` as the writer reaches it.
    static func entries(agent: URL) throws -> [ISO9660Entry] {
        let script = try resource("agent-disk.sh")
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
            ISO9660Entry(name: "README.txt", permissions: 0o644, bytes: try resource("README.txt")),
            ISO9660Entry(name: "LICENSES.txt", permissions: 0o644, bytes: try resource("LICENSES.txt")),
        ]
    }

    /// The bytes of `name` in the disk's resource directory.
    static func resource(_ name: String) throws -> [UInt8] {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let url = Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "LinuxAgentDisk") else {
            assertionFailure("LinuxAgentDisk/\(name) missing from KernovaCore's resources")
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "LinuxAgentDisk/\(name)"])
        }
        return Array(try Data(contentsOf: url))
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

    /// A cache writing its image into `directory`.
    package init(directory: URL) {
        url = directory.appending(path: "linux-arm64.iso", directoryHint: .notDirectory)
    }

    /// The one the app uses, beside the VM library in Application Support.
    package static let production = GuestAgentDiskCache(
        directory: URL.applicationSupportDirectory.appending(
            path: "Kernova/GuestAgentDisks", directoryHint: .isDirectory))

    /// The image holding `agent`, written on this process's first ask, off the caller's actor; a write that
    /// failed is tried again on the next ask.
    func disk(agent: URL) async throws -> URL {
        let task = made.withLock { made in
            if let task = made { return task }
            let url = url
            let task = Task.detached(priority: .utility) { () throws -> URL in
                try Self.write(LinuxAgentDisk.entries(agent: agent), to: url)
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
