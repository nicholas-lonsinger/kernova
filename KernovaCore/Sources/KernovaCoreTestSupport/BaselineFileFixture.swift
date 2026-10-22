import Foundation

@testable import KernovaCore

/// The files a snapshot captured and the bundle's own copies of them, laid down
/// on disk for the predicate that reads them by size and modification date
/// (``VMInstance/restsOff(_:)``).
extension VMBundleLayout {
    /// The bundle-relative path of the suspend slot, and of a warm snapshot's
    /// saved state inside its own directory.
    static var saveFilePathForTesting: String { saveFileRelativePath }

    /// The main disk's bundle-relative path.
    var mainDiskPathForTesting: String { diskImageURL.lastPathComponent }

    /// Writes `relativePath` into snapshot `id`'s directory, as its capture
    /// left it.
    func writeCaptured(_ relativePath: String, ofSnapshot id: UUID) throws {
        try Self.write(
            "captured \(relativePath)",
            to: snapshotLayout(id: id).bundleURL.appendingPathComponent(relativePath),
            modified: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// Clones snapshot `id`'s `relativePath` into the bundle as a revert
    /// installs it: `copyItem` keeps the size and the modification date.
    func installCaptured(_ relativePath: String, fromSnapshot id: UUID) throws {
        let destination = bundleURL.appendingPathComponent(relativePath)
        let manager = FileManager.default
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.removeItem(at: destination)
        try manager.copyItem(
            at: snapshotLayout(id: id).bundleURL.appendingPathComponent(relativePath),
            to: destination)
    }

    /// Writes `relativePath` in the bundle as a running guest does — fresh
    /// contents stamped with a modification date no capture carries.
    func writeAsGuest(_ relativePath: String) throws {
        try Self.write(
            "written by the guest \(relativePath)",
            to: bundleURL.appendingPathComponent(relativePath),
            modified: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private static func write(_ contents: String, to url: URL, modified: Date) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
}
