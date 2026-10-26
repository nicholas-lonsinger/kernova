import AppleArchive
import Darwin
import Foundation
import KernovaKit
import System

/// One entry of an archive a test writes through AppleArchive's C API, so its
/// strings can carry any bytes — including entries no sender writes. A `nil`
/// field is left out of the header.
public struct RawArchiveEntry {
    /// The `TYP` field.
    public var type: ArchiveHeader.EntryType?
    /// The `PAT` field, as raw bytes; empty for the root.
    public var path: [UInt8]
    /// The `LNK` field, as raw bytes.
    public var link: [UInt8]?
    /// The `UID` field.
    public var uid: UInt64?
    /// The `GID` field.
    public var gid: UInt64?
    /// The `MOD` field.
    public var mode: UInt64?
    /// The `FLG` field.
    public var flags: UInt64?
    /// The `CTM` field.
    public var creation: timespec?
    /// The `MTM` field.
    public var modification: timespec?
    /// The `DAT` blob.
    public var data: Data?
    /// Blob fields other than `DAT`, each declared and written ahead of it.
    public var blobsBefore: [(key: String, data: Data)]
    /// Blob fields other than `DAT`, each declared and written after it.
    public var blobsAfter: [(key: String, data: Data)]
    /// Applied to the header's encoding before it is written, to make one the
    /// C API's setters refuse.
    public var editEncoding: ((inout [UInt8]) -> Void)?

    /// An entry carrying exactly the fields given.
    public init(
        type: ArchiveHeader.EntryType?, path: [UInt8], link: [UInt8]? = nil, uid: UInt64? = nil,
        gid: UInt64? = nil, mode: UInt64? = nil, flags: UInt64? = nil, creation: timespec? = nil,
        modification: timespec? = nil, data: Data? = nil,
        blobsBefore: [(key: String, data: Data)] = [], blobsAfter: [(key: String, data: Data)] = [],
        editEncoding: ((inout [UInt8]) -> Void)? = nil
    ) {
        self.type = type
        self.path = path
        self.link = link
        self.uid = uid
        self.gid = gid
        self.mode = mode
        self.flags = flags
        self.creation = creation
        self.modification = modification
        self.data = data
        self.blobsBefore = blobsBefore
        self.blobsAfter = blobsAfter
        self.editEncoding = editEncoding
    }

    /// A directory at `path`.
    public static func directory(_ path: String, mode: UInt64 = 0o755) -> RawArchiveEntry {
        RawArchiveEntry(type: .directory, path: Array(path.utf8), mode: mode)
    }

    /// A regular file at `path` holding `contents`.
    public static func file(_ path: String, _ contents: String = "", mode: UInt64 = 0o644)
        -> RawArchiveEntry
    {
        RawArchiveEntry(type: .regularFile, path: Array(path.utf8), mode: mode, data: Data(contents.utf8))
    }

    /// The root entry, whose attributes land on the destination itself.
    public static func root(mode: UInt64 = 0o755) -> RawArchiveEntry {
        RawArchiveEntry(type: .directory, path: [], mode: mode)
    }
}

/// What stopped ``rawArchive(_:)`` writing an archive.
private struct RawArchiveError: Error, Sendable {
    /// The stream or header AppleArchive refused.
    let step: String
}

/// The LZ4 archive holding `entries`, in order, with their fields in the
/// order the clipboard archive's field keys list them.
public func rawArchive(_ entries: [RawArchiveEntry]) throws -> Data {
    let sink = RawArchiveSink()
    do {
        guard let bytes = ArchiveByteStream.customStream(instance: sink) else {
            throw RawArchiveError(step: "custom stream")
        }
        defer { try? bytes.close() }
        guard let compress = ArchiveByteStream.compressionStream(using: .lz4, writingTo: bytes) else {
            throw RawArchiveError(step: "compression stream")
        }
        defer { try? compress.close() }
        guard let encode = ArchiveStream.encodeStream(writingTo: compress) else {
            throw RawArchiveError(step: "encode stream")
        }
        defer { try? encode.close() }
        for entry in entries {
            let blobs =
                entry.blobsBefore + (entry.data.map { [(key: "DAT", data: $0)] } ?? []) + entry.blobsAfter
            try encode.writeHeader(try header(for: entry, blobs: blobs))
            for blob in blobs where !blob.data.isEmpty {
                try blob.data.withUnsafeBytes { try encode.writeBlob(key: .init(blob.key), from: $0) }
            }
        }
    }
    return sink.bytes
}

private func header(for entry: RawArchiveEntry, blobs: [(key: String, data: Data)]) throws -> ArchiveHeader {
    guard let builder = ClipboardArchiveHeaderBuilder() else { throw RawArchiveError(step: "header") }
    if let type = entry.type { builder.append(uint: UInt64(type.rawValue), key: "TYP") }
    builder.append(string: entry.path, key: "PAT")
    if let link = entry.link { builder.append(string: link, key: "LNK") }
    if let uid = entry.uid { builder.append(uint: uid, key: "UID") }
    if let gid = entry.gid { builder.append(uint: gid, key: "GID") }
    if let mode = entry.mode { builder.append(uint: mode, key: "MOD") }
    if let flags = entry.flags { builder.append(uint: flags, key: "FLG") }
    if let creation = entry.creation { builder.append(timespec: creation, key: "CTM") }
    if let modification = entry.modification { builder.append(timespec: modification, key: "MTM") }
    for blob in blobs { builder.append(blobSize: UInt64(blob.data.count), key: blob.key) }
    guard let made = builder.make() else { throw RawArchiveError(step: "header fields") }
    guard let editEncoding = entry.editEncoding else { return made }
    var encoded = made.withAAEncodedData { Array($0) }
    editEncoding(&encoded)
    guard let edited = encoded.withUnsafeBufferPointer({ ArchiveHeader(withAAEncodedData: $0) }) else {
        throw RawArchiveError(step: "edited header")
    }
    return edited
}

/// Collects every encoded byte into one buffer.
private final class RawArchiveSink: ArchiveByteStreamProtocol {
    private(set) var bytes = Data()

    func write(from buffer: UnsafeRawBufferPointer) throws -> Int {
        bytes.append(contentsOf: buffer)
        return buffer.count
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int { throw Errno.notSupported }

    func read(into buffer: UnsafeMutableRawBufferPointer, atOffset offset: Int64) throws -> Int {
        throw Errno.notSupported
    }

    func write(from buffer: UnsafeRawBufferPointer, atOffset offset: Int64) throws -> Int {
        throw Errno.notSupported
    }

    func seek(toOffset offset: Int64, relativeTo origin: FileDescriptor.SeekOrigin) throws -> Int64 {
        throw Errno.notSupported
    }

    func close() throws {}

    func cancel() {}
}
