import Foundation

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
