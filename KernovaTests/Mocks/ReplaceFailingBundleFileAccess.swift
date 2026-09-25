import Foundation

@testable import Kernova

/// ``CoordinatedBundleFileAccess`` over real files, except that a replace of
/// any path in ``failingPaths`` throws instead of landing — the file-system
/// seam an atomic replace that fails is injected through. Every replace that
/// lands is recorded.
final class ReplaceFailingBundleFileAccess: VMBundleFileAccessing, @unchecked Sendable {
    struct InjectedFailure: Error {}

    private let lock = NSLock()
    private var failing: Set<String> = []
    private var replaced: [String] = []
    private let disk = CoordinatedBundleFileAccess()

    init(failing: Set<String> = []) {
        self.failing = failing
    }

    /// Bundle-relative paths whose replace throws ``InjectedFailure``.
    var failingPaths: Set<String> {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    /// Every bundle-relative path a replace landed at, in order.
    var replacedPaths: [String] { lock.withLock { replaced } }

    func reading<T>(_ bundleURL: URL, _ body: (any VMBundleFileReading) throws -> T) throws -> T {
        try disk.reading(bundleURL, body)
    }

    func writing<T>(_ bundleURL: URL, _ body: (any VMBundleFileWriting) throws -> T) throws -> T {
        try disk.writing(bundleURL) { files in try body(Handle(wrapped: files, owner: self)) }
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
            owner.lock.withLock { owner.replaced.append(relativePath) }
        }
    }
}
