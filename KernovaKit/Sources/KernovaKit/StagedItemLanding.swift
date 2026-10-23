import Foundation

/// Moves an item a pull delivered out of staging to where the user wanted it.
///
/// A pull lands only in staging, and its receiver deletes its extract
/// destination on failure, so it is never pointed at a user's folder: staging
/// then moving is how a received file or folder reaches one.
public enum StagedItemLanding {
    /// Moves `representation`'s staged file or folder to exactly `destination`.
    ///
    /// Never replaces an existing item.
    ///
    /// - Throws: `CocoaError(.fileNoSuchFile)` for a representation with no
    ///   staged file, or the move's error when the item could not be put at
    ///   `destination`.
    public static func land(
        _ representation: ClipboardContent.Representation, at destination: URL
    ) throws {
        guard let source = representation.fileURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.moveItem(at: source, to: destination)
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
        guard let source = representation.fileURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = NameUniquing.uniqueDestination(
            in: directory, filename: filename.isEmpty ? source.lastPathComponent : filename)
        try land(representation, at: destination)
        return destination
    }
}
