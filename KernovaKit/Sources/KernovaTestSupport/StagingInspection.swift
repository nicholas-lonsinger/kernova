import Foundation

/// A `@Sendable`-safe mutable cell — lets a synchronous test closure record what
/// it observed from a concurrency-checked context.
///
/// One copy for every test target, since all three need it.
public final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    /// Creates a cell holding `value`.
    public init(_ value: T) { stored = value }

    /// The current value; reads and writes are serialized.
    public var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Every regular file anywhere under `directory` (recursive).
///
/// What a test asserts against to prove a transfer staged nothing it shouldn't
/// have — an intermediate archive, or a partial left behind by an abort.
public func materializedFiles(under directory: URL) -> [URL] {
    guard
        let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter {
        (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }
}
