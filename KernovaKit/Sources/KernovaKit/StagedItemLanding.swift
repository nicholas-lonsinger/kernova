import Foundation

/// Moves an item a pull delivered out of staging to where the user wanted it.
///
/// A pull lands only in staging, and its receiver deletes its extract
/// destination on failure, so it is never pointed at a user's folder: staging
/// then moving is how a received file or folder reaches one. A rename when
/// staging shares the destination's volume, so nothing payload-scaled happens
/// there; a cross-device move falls back to copy-and-delete.
public enum StagedItemLanding {
    /// Moves `representation`'s staged file or folder to exactly `destination`.
    ///
    /// Never replaces an existing item: the move throws instead.
    ///
    /// - Throws: `CocoaError(.fileNoSuchFile)` for a representation with no
    ///   staged file, or the move's or copy's error.
    public static func land(
        _ representation: ClipboardContent.Representation, at destination: URL
    ) throws {
        try land(representation, at: destination, move: FileManager.default.moveItem)
    }

    /// Moves `representation`'s staged file or folder into `directory` under
    /// `filename` — sanitized to one path component, and counted up Finder's
    /// "Keep Both" way when the name is taken — returning where it landed.
    ///
    /// An empty `filename` keeps the staged item's own name. `directory` is
    /// created if it does not exist.
    public static func land(
        _ representation: ClipboardContent.Representation, inDirectory directory: URL,
        named filename: String
    ) throws -> URL {
        try land(
            representation, inDirectory: directory, named: filename,
            move: FileManager.default.moveItem)
    }

    // MARK: - Seams

    /// ``land(_:at:)`` with the rename injected, so a test can stand in a
    /// cross-device one.
    static func land(
        _ representation: ClipboardContent.Representation, at destination: URL,
        move: (URL, URL) throws -> Void
    ) throws {
        guard let source = representation.fileURL else { throw CocoaError(.fileNoSuchFile) }
        do {
            try move(source, destination)
        } catch let error as NSError where isCrossDevice(error) {
            try FileManager.default.copyItem(at: source, to: destination)
            // Staging is app-internal, so its copy is removed outright.
            try? FileManager.default.removeItem(at: source)
        }
    }

    /// ``land(_:inDirectory:named:)`` with the rename injected.
    static func land(
        _ representation: ClipboardContent.Representation, inDirectory directory: URL,
        named filename: String, move: (URL, URL) throws -> Void
    ) throws -> URL {
        guard let source = representation.fileURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = NameUniquing.uniqueDestination(
            in: directory, filename: filename.isEmpty ? source.lastPathComponent : filename)
        try land(representation, at: destination, move: move)
        return destination
    }

    private static func isCrossDevice(_ error: NSError) -> Bool {
        (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(EXDEV)
            || error.code == Int(EXDEV)
    }
}
