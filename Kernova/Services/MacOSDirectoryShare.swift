import Foundation
import Virtualization

/// The share a macOS guest's one directory-sharing device carries: each shared
/// folder, resolved and validated, under the name the guest mounts it by.
///
/// Built only by ``ConfigurationBuilder/macOSDirectoryShare(for:)``, for a boot
/// and for a live share swap alike.
struct MacOSDirectoryShare: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        /// The ``SharedDirectory/id`` this entry shares.
        let id: UUID
        let name: String
        let url: URL
        let readOnly: Bool
    }

    let entries: [Entry]

    /// The Virtualization share this describes.
    func makeShare() -> VZMultipleDirectoryShare {
        VZMultipleDirectoryShare(
            directories: Dictionary(
                entries.map { ($0.name, VZSharedDirectory(url: $0.url, readOnly: $0.readOnly)) },
                uniquingKeysWith: { _, last in last }))
    }
}
