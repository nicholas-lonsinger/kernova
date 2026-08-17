import Foundation
import KernovaKit

/// The payload bytes an archived transfer carries for `source` — what a data
/// connection carries for a folder, a file, or an oversize inline payload.
///
/// A test standing in for the producing side writes its payload with this, and
/// one standing in for the consuming side checks the bytes it collected against
/// `extractedClipboardArchive(_:)`.
public func clipboardArchiveBytes(of source: ClipboardArchiveSource) throws -> Data {
    try ClipboardArchive.archiveBytes(of: source)
}

/// The payload bytes a folder transfer carries for `directoryURL`.
public func clipboardArchiveBytes(ofDirectoryAt directoryURL: URL) throws -> Data {
    try clipboardArchiveBytes(of: .directory(directoryURL))
}

/// The payload bytes a file transfer carries for the file at `fileURL`, named
/// `name` in the archive (its own name by default) and carrying its current
/// size.
public func clipboardArchiveBytes(ofFileAt fileURL: URL, named name: String? = nil) throws
    -> Data
{
    let byteCount = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    return try clipboardArchiveBytes(
        of: .file(fileURL, name: name ?? fileURL.lastPathComponent, byteCount: byteCount))
}

/// Extracts archived-transfer payload bytes into a fresh directory, which it
/// returns: a folder's tree lands directly inside it, a file's one entry as its
/// single child.
///
/// - Throws: whatever the extract reports for a truncated or corrupt archive;
///   the partial output is removed in that case.
public func extractedClipboardArchive(_ bytes: Data, named name: String = "out") throws -> URL {
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("archive-fixture-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    do {
        try ClipboardArchive.extract(bytes, into: destination)
        return destination
    } catch {
        try? FileManager.default.removeItem(at: destination)
        throw error
    }
}
