import Foundation
import KernovaCore
import Virtualization

extension MacOSDirectoryShare {
    /// The Virtualization share this describes.
    func makeShare() -> VZMultipleDirectoryShare {
        VZMultipleDirectoryShare(
            directories: Dictionary(
                uniqueKeysWithValues: entries.map {
                    ($0.name, VZSharedDirectory(url: $0.url, readOnly: $0.readOnly))
                }))
    }
}
