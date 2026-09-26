import Foundation

/// A directory under the temporary directory that no other test shares,
/// removed with everything under it when this object goes away.
///
/// A suite holds one as a stored property, so each test gets its own.
public final class TestScratchDirectory: Sendable {
    /// The directory; nothing exists there until a test creates it.
    ///
    /// Named `<prefix>-` and 12 hex digits: unique across runs, and short
    /// enough that a socket path under it fits `sockaddr_un.sun_path`.
    public let url: URL

    /// A fresh directory name; touches no disk.
    ///
    /// - Parameter prefix: starts the name, so leftovers name their suite.
    public init(prefix: String) {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(suffix)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
