import Foundation

/// Every permission withheld from one file or folder for as long as this value
/// lives, then handed back — so the item is unreadable to the test's own
/// process, and its scratch directory can still be swept afterwards.
public final class WithheldPermissions {
    private let path: String
    private let mode: Int

    /// Withholds every permission from the item at `url`.
    public init(_ url: URL) throws {
        path = url.path
        let fm = FileManager.default
        mode = (try fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }
}
