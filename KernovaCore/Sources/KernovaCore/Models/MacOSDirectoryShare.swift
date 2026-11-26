import Foundation

/// The share a macOS guest's one directory-sharing device carries: each shared
/// folder, resolved and validated, under the name the guest mounts it by.
///
/// Built only by ``make(for:serving:host:)``, for a boot and for a live share
/// swap alike, so no two entries carry one name and Virtualization accepts
/// every entry's.
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
    /// the running device `serving` carries, what a live swap installs — each
    /// entry under its share's ``SharedDirectory/name``, which `host`'s
    /// Virtualization accepts or the share is refused
    /// (``ConfigurationBuilderError/sharedDirectoryNameRefused(id:path:label:underlying:)``).
    ///
    /// An entry `serving` already carries keeps its host folder as the device
    /// serves it — re-validated at that folder only when its access changed —
    /// so a swap moves nothing the edit did not. Every other entry is resolved
    /// and validated from its path.
    package static func make(
        for directories: NamedList<SharedDirectory>, serving: MacOSDirectoryShare? = nil,
        host: any VirtualizationHostProviding
    ) throws -> MacOSDirectoryShare {
        let served = Dictionary(
            (serving?.entries ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return MacOSDirectoryShare(
            entries: try directories.map { directory in
                if let refusal = host.directoryShareNameRefusal(directory.name) {
                    throw ConfigurationBuilderError.sharedDirectoryNameRefused(
                        id: directory.id, path: directory.path, label: directory.name, underlying: refusal)
                }
                guard let entry = served[directory.id] else {
                    return Entry(
                        id: directory.id, name: directory.name,
                        url: try ConfigurationPaths.resolveSharedDirectory(directory), readOnly: directory.readOnly)
                }
                guard entry.readOnly != directory.readOnly else {
                    return Entry(id: entry.id, name: directory.name, url: entry.url, readOnly: entry.readOnly)
                }
                let servedPath = (entry.url.path(percentEncoded: false) as NSString).standardizingPath
                return Entry(
                    id: entry.id, name: directory.name,
                    url: try ConfigurationPaths.resolveSharedDirectory(directory, at: servedPath),
                    readOnly: directory.readOnly)
            })
    }
}
