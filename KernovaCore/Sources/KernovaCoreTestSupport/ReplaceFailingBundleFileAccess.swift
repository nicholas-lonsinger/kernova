import Foundation
import Synchronization

@testable import KernovaCore

/// ``CoordinatedBundleFileAccess`` over real files, except that a replace of
/// any path in ``failingPaths`` throws instead of landing — the file-system
/// seam an atomic replace that fails is injected through. Every replace that
/// lands is recorded.
final class ReplaceFailingBundleFileAccess: VMBundleFileAccessing {
    struct InjectedFailure: Error {}

    /// Bundle-relative paths whose replace throws ``InjectedFailure``.
    let failingPaths: Set<String>
    private let replaced = Mutex<[String]>([])
    private let disk = CoordinatedBundleFileAccess()

    init(failing: Set<String> = []) {
        failingPaths = failing
    }

    /// Every bundle-relative path a replace landed at, in order.
    var replacedPaths: [String] { replaced.withLock { $0 } }

    func reading<T>(_ bundleURL: URL, _ body: (any VMBundleFileReading) throws -> T) throws -> T {
        try disk.reading(bundleURL, body)
    }

    func lockBundle(at bundleURL: URL) throws -> (any VMBundleLockHolder)? {
        try disk.lockBundle(at: bundleURL)
    }

    func isBundleLockedElsewhere(at bundleURL: URL) throws -> Bool {
        try disk.isBundleLockedElsewhere(at: bundleURL)
    }

    func writing<T>(
        _ bundleURL: URL, _ key: borrowing VMBundleFileWriteKey,
        _ body: (any VMBundleFileWriting) throws -> T
    ) throws -> T {
        try disk.writing(bundleURL, key) { files in try body(Handle(wrapped: files, owner: self)) }
    }

    private struct Handle: VMBundleFileWriting {
        let wrapped: any VMBundleFileWriting
        let owner: ReplaceFailingBundleFileAccess

        func data(atRelativePath relativePath: String) throws -> Data? {
            try wrapped.data(atRelativePath: relativePath)
        }

        func replace(atRelativePath relativePath: String, with data: Data) throws {
            if owner.failingPaths.contains(relativePath) { throw InjectedFailure() }
            try wrapped.replace(atRelativePath: relativePath, with: data)
            owner.replaced.withLock { $0.append(relativePath) }
        }
    }
}
