import Foundation
import Virtualization

extension MacOSDirectoryShare {
    /// The Virtualization share this describes.
    func makeShare() -> VZMultipleDirectoryShare {
        VZMultipleDirectoryShare(
            directories: Dictionary(
                entries.map { ($0.name, VZSharedDirectory(url: $0.url, readOnly: $0.readOnly)) },
                uniquingKeysWith: { _, last in last }))
    }
}
