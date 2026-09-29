import Foundation
import Testing

/// A directory under the temporary directory that no other test shares,
/// removed with everything under it when the test case that minted it ends,
/// however long anything holds the value.
///
/// A suite holds one as a stored property, so each test gets its own. Minting
/// takes the running case's scratch ledger, which only ``TestCaseScopeTrait``
/// installs.
public struct TestScratchDirectory: Sendable {
    /// The directory; nothing exists there until a test creates it.
    ///
    /// Named `<prefix>-` and 12 hex digits: unique across runs, and short
    /// enough that a socket path under it fits `sockaddr_un.sun_path`.
    public let url: URL

    /// A fresh directory name, removed when the running test case ends;
    /// touches no disk.
    ///
    /// - Parameter prefix: starts the name, so leftovers name their suite.
    public init(prefix: String) {
        let caller = "TestScratchDirectory(prefix: \"\(prefix)\")"
        url = TestScratchLedger.running(minting: caller).mint(prefix, for: caller)
    }

    private init(url: URL) {
        self.url = url
    }

    /// The one directory named by `prefix` for the running test case: every
    /// call in the same case returns the same directory, and the case's end
    /// removes it — for a fixture with no suite instance to hold one.
    public static func forCase(prefix: String) -> Self {
        let caller = "TestScratchDirectory.forCase(prefix: \"\(prefix)\")"
        return Self(url: TestScratchLedger.running(minting: caller).shared(prefix, for: caller))
    }

    /// Whether the volume every scratch directory sits on folds case; mints
    /// nothing, so a trait condition may ask it.
    public static var volumeFoldsCase: Bool {
        let values = try? parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values?.volumeSupportsCaseSensitiveNames == false
    }

    fileprivate static var parent: URL {
        FileManager.default.temporaryDirectory
    }

    fileprivate static func freshURL(_ prefix: String) -> URL {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        return parent.appendingPathComponent("\(prefix)-\(suffix)", isDirectory: true)
    }
}

/// The scratch directories one test case minted, removed when the case ends,
/// after which it takes no more.
///
/// `@unchecked Sendable`: `lock` serializes every access to `urls`,
/// `sharedURLs` and `isClosed`.
final class TestScratchLedger: @unchecked Sendable {
    /// The running case's ledger; `nil` outside a ``TestCaseScopeTrait`` scope.
    @TaskLocal static var current: TestScratchLedger?

    private let lock = NSLock()
    private var urls: [URL] = []
    private var sharedURLs: [String: URL] = [:]
    private var isClosed = false

    /// Every directory recorded so far, in minting order.
    var recordedURLs: [URL] { lock.withLock { urls } }

    /// Runs `body` with a fresh ledger as ``current``, then removes every
    /// directory recorded in it, whether `body` returned or threw.
    ///
    /// A removal that fails for any reason but absence is recorded as an issue
    /// against the running test: the directory would otherwise outlive it.
    static func scoping<Value>(
        _ body: () async throws -> Value
    ) async rethrows -> Value {
        let ledger = TestScratchLedger()
        defer { ledger.removeAll() }
        return try await $current.withValue(ledger) { try await body() }
    }

    /// The ledger of the running case, which `caller` needs to mint.
    fileprivate static func running(minting caller: @autoclosure () -> String) -> TestScratchLedger {
        guard let current else {
            preconditionFailure(
                """
                \(caller()) ran outside a scoped test case. Only a case running under the .caseScoped \
                trait has a scratch ledger; a suite without the trait, Task.detached, a trait condition \
                such as .enabled(if:), arguments:, a static, and a GCD callback all run outside one.
                """)
        }
        return current
    }

    fileprivate func mint(_ prefix: String, for caller: @autoclosure () -> String) -> URL {
        let url = TestScratchDirectory.freshURL(prefix)
        let recorded = lock.withLock {
            guard !isClosed else { return false }
            urls.append(url)
            return true
        }
        guard recorded else { Self.caseEnded(caller()) }
        return url
    }

    fileprivate func shared(_ prefix: String, for caller: @autoclosure () -> String) -> URL {
        let url: URL? = lock.withLock {
            guard !isClosed else { return nil }
            if let url = sharedURLs[prefix] { return url }
            let url = TestScratchDirectory.freshURL(prefix)
            urls.append(url)
            sharedURLs[prefix] = url
            return url
        }
        guard let url else { Self.caseEnded(caller()) }
        return url
    }

    private static func caseEnded(_ caller: String) -> Never {
        preconditionFailure(
            """
            \(caller) ran after its test case had already ended and removed its scratch, from work the \
            case started without awaiting, such as an unstructured Task. Nothing would remove this \
            directory; await that work before the case returns.
            """)
    }

    private func removeAll() {
        let recorded = lock.withLock {
            isClosed = true
            return urls
        }
        for url in recorded {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                Issue.record(error, "Scratch directory \(url.path) outlived its test case")
            }
        }
    }
}
