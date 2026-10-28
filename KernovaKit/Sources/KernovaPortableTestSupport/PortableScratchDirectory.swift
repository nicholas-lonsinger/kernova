#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A directory under the temporary directory that no other test shares, made when this is, and removed with
/// everything under it when the last reference goes: the scratch of the test targets that build where
/// `KernovaTestSupport` and its `TestScratchDirectory` do not.
///
/// A suite holds one as a stored property, so each test gets its own and its end removes it.
public final class PortableScratchDirectory: Sendable {
    /// The directory, which exists.
    public let url: URL

    /// Makes a fresh directory named `<prefix>-<12 hex digits>`.
    public init(prefix: String) throws {
        let suffix = UUID().uuidString.split(separator: "-").joined().prefix(12).lowercased()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    /// The directory's path, as a system call takes it.
    public var path: String { url.path }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
