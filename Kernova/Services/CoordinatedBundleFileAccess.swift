import Foundation

/// ``VMBundleFileAccessing`` over the real files, coordinated with
/// `NSFileCoordinator` on the bundle directory.
///
/// Every Kernova process coordinates on the same directory URL, so two copies
/// editing one VM exclude each other whether or not the `.kernova` type is
/// registered: coordination crosses processes and the App Sandbox
/// (`docs/research/2026-09-24-file-coordination-rename-and-flock.md`).
///
/// Registers no file presenter: a presenter on a package makes every later
/// coordinated access to it wait about half a second, and one that never
/// answers stalls other processes' writes (same note).
struct CoordinatedBundleFileAccess: VMBundleFileAccessing {
    func reading<T>(_ bundleURL: URL, _ body: (any VMBundleFileReading) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, any Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: bundleURL, options: [], error: &coordinationError
        ) { url in
            result = Result { try body(DiskBundleFiles(root: url)) }
        }
        return try Self.outcome(result, coordinationError)
    }

    func writing<T>(_ bundleURL: URL, _ body: (any VMBundleFileWriting) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, any Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: bundleURL, options: [], error: &coordinationError
        ) { url in
            result = Result { try body(DiskBundleFiles(root: url)) }
        }
        return try Self.outcome(result, coordinationError)
    }

    /// The accessor's result, or the error that kept the accessor from running.
    private static func outcome<T>(_ result: Result<T, any Error>?, _ coordinationError: NSError?)
        throws -> T
    {
        if let result { return try result.get() }
        throw coordinationError ?? CocoaError(.fileReadUnknown)
    }
}

/// One bundle's files on disk, as handed to a coordinated accessor.
private struct DiskBundleFiles: VMBundleFileWriting {
    let root: URL

    func data(atRelativePath relativePath: String) throws -> Data? {
        do {
            return try Data(contentsOf: root.appendingPathComponent(relativePath))
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        {
            return nil
        }
    }

    /// Creates the directory the file sits in when it is inside the bundle and
    /// missing — never the bundle itself, so a write to a bundle that is not
    /// there fails rather than inventing one.
    func replace(atRelativePath relativePath: String, with data: Data) throws {
        let url = root.appendingPathComponent(relativePath)
        let parent = url.deletingLastPathComponent()
        if parent.standardizedFileURL != root.standardizedFileURL,
            !FileManager.default.fileExists(atPath: parent.path(percentEncoded: false))
        {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        }
        try data.write(to: url, options: .atomic)
    }
}
