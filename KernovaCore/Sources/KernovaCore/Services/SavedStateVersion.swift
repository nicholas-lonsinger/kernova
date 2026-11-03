import Foundation

/// The Kernova build that wrote a saved state, as its
/// ``AppBundleProducts/versionLabel``, kept in an extended attribute on the
/// saved-state file itself — so it travels with every clone, `copyItem` and
/// rename of the file, which is how a saved state moves between the suspend
/// slot, a snapshot and another bundle.
package enum SavedStateVersion {
    private static let attributeName = "app.kernova.saved-by"

    /// Records `versionLabel` as the writer of the saved state at `url`.
    ///
    /// - Throws: a `POSIXError` when the attribute can't be written.
    package static func record(_ versionLabel: String, at url: URL) throws {
        let value = Array(versionLabel.utf8)
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return setxattr(path, attributeName, value, value.count, 0, XATTR_NOFOLLOW)
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// The version that wrote the saved state at `url`, or `nil` when there is
    /// no file there, or it carries no record — a state written before Kernova
    /// recorded one.
    package static func read(at url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let size = getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return nil }
            var value = [UInt8](repeating: 0, count: size)
            let read = getxattr(path, attributeName, &value, size, 0, XATTR_NOFOLLOW)
            guard read > 0 else { return nil }
            return String(decoding: value.prefix(read), as: UTF8.self)
        }
    }
}
