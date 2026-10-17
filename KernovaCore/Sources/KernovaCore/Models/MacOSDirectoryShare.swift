import Foundation

/// The share a macOS guest's one directory-sharing device carries: each shared
/// folder, resolved and validated, under the name the guest mounts it by.
///
/// Built only by ``make(for:serving:)``, for a boot and for a live share swap
/// alike.
package struct MacOSDirectoryShare: Sendable, Equatable {
    package struct Entry: Sendable, Equatable {
        /// The ``SharedDirectory/id`` this entry shares.
        let id: UUID
        package let name: String
        package let url: URL
        package let readOnly: Bool
    }

    package let entries: [Entry]

    /// The share a macOS guest's one directory-sharing device carries for
    /// `directories` — what a boot builds the device with, and, given the share
    /// the running device `serving` carries, what a live swap installs.
    ///
    /// An entry `serving` already carries keeps its mount name and host folder
    /// as the device serves them — re-validated at that folder only when its
    /// access changed — so a swap moves nothing the edit did not. Every other
    /// entry is resolved and validated from its path, under its
    /// ``SharedDirectory/mountName`` unless a name already taken forces the id
    /// prefix.
    package static func make(
        for directories: [SharedDirectory], serving: MacOSDirectoryShare? = nil
    ) throws -> MacOSDirectoryShare {
        let served = Dictionary(
            (serving?.entries ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var names = Set(directories.compactMap { served[$0.id]?.name })
        var entries: [MacOSDirectoryShare.Entry] = []
        for directory in directories {
            if let entry = served[directory.id] {
                guard entry.readOnly != directory.readOnly else {
                    entries.append(entry)
                    continue
                }
                let servedPath =
                    (entry.url.path(percentEncoded: false) as NSString)
                    .standardizingPath
                entries.append(
                    Entry(
                        id: entry.id, name: entry.name,
                        url: try ConfigurationPaths.resolveSharedDirectory(directory, at: servedPath),
                        readOnly: directory.readOnly))
                continue
            }
            var name = directory.mountName
            // A list whose stored names collide — a hand-edited config.json —
            // still needs one key per folder.
            if names.contains(name) {
                name = "\(directory.id.uuidString.prefix(8))-\(name)"
            }
            names.insert(name)
            entries.append(
                Entry(
                    id: directory.id, name: name, url: try ConfigurationPaths.resolveSharedDirectory(directory),
                    readOnly: directory.readOnly))
        }
        return MacOSDirectoryShare(entries: entries)
    }
}
