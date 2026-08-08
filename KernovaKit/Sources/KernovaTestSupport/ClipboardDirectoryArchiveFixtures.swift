import Foundation
import KernovaKit

/// The wire bytes a folder transfer carries for `directoryURL` — what
/// `ClipboardStreamSender.startDirectoryTransfer` puts on the channel.
///
/// A test standing in for the producing side builds its payload with this, and
/// one standing in for the consuming side checks the bytes it collected against
/// `extractedClipboardArchive(_:)`.
public func clipboardArchiveBytes(ofDirectoryAt directoryURL: URL) throws -> Data {
    let reader = ClipboardDirectoryArchiveReader(directoryURL: directoryURL, label: "fixture")
    var bytes = Data()
    while true {
        let chunk = try reader.read(upTo: 64 << 10)
        if chunk.isEmpty { break }
        bytes.append(chunk)
    }
    return bytes
}

/// Extracts folder-transfer wire bytes into a fresh directory, which it returns.
///
/// - Throws: whatever the extract pipeline reports for a truncated or corrupt
///   archive; the partial tree is removed in that case.
public func extractedClipboardArchive(_ bytes: Data, named name: String = "out") throws -> URL {
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("archive-fixture-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let sink = ClipboardDirectoryExtractSink(destinationURL: destination, label: "fixture")
    do {
        try sink.write(bytes)
        return try sink.commit()
    } catch {
        sink.abort()
        throw error
    }
}
