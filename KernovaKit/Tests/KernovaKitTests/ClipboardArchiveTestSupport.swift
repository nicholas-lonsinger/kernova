import AppleArchive
import Darwin
import Foundation
import KernovaSynchronization
import System
import Testing

@testable import KernovaKit

// MARK: - Archives written field by field

/// One entry of an archive a test writes through AppleArchive's C API, so its
/// strings can carry any bytes — including entries no sender writes.
struct RawArchiveEntry {
    var type: ArchiveHeader.EntryType?
    var path: [UInt8]
    var link: [UInt8]? = nil
    var uid: UInt64? = nil
    var gid: UInt64? = nil
    var mode: UInt64? = nil
    var flags: UInt64? = nil
    var creation: timespec? = nil
    var modification: timespec? = nil
    var data: Data? = nil
    /// Blob fields other than `DAT`, each declared and written ahead of it.
    var blobsBefore: [(key: String, data: Data)] = []
    /// Blob fields other than `DAT`, each declared and written after it.
    var blobsAfter: [(key: String, data: Data)] = []
    /// Applied to the header's encoding before it is written, to make one the
    /// C API's setters refuse.
    var editEncoding: ((inout [UInt8]) -> Void)? = nil

    static func directory(_ path: String, mode: UInt64 = 0o755) -> RawArchiveEntry {
        RawArchiveEntry(type: .directory, path: Array(path.utf8), mode: mode)
    }

    static func file(_ path: String, _ contents: String = "", mode: UInt64 = 0o644) -> RawArchiveEntry {
        RawArchiveEntry(type: .regularFile, path: Array(path.utf8), mode: mode, data: Data(contents.utf8))
    }

    /// The root entry, whose attributes land on the destination itself.
    static func root(mode: UInt64 = 0o755) -> RawArchiveEntry {
        RawArchiveEntry(type: .directory, path: [], mode: mode)
    }
}

/// The LZ4 archive holding `entries`, in order, with their fields in
/// ``ClipboardArchive/fieldKeys`` order.
func rawArchive(_ entries: [RawArchiveEntry]) throws -> Data {
    let sink = ClipboardArchiveDataSink()
    do {
        let bytes = try #require(ArchiveByteStream.customStream(instance: sink))
        defer { try? bytes.close() }
        let compress = try #require(ArchiveByteStream.compressionStream(using: .lz4, writingTo: bytes))
        defer { try? compress.close() }
        let encode = try #require(ArchiveStream.encodeStream(writingTo: compress))
        defer { try? encode.close() }
        for entry in entries {
            let builder = try #require(ClipboardArchiveHeaderBuilder())
            if let type = entry.type { builder.append(uint: UInt64(type.rawValue), key: "TYP") }
            builder.append(string: entry.path, key: "PAT")
            if let link = entry.link { builder.append(string: link, key: "LNK") }
            if let uid = entry.uid { builder.append(uint: uid, key: "UID") }
            if let gid = entry.gid { builder.append(uint: gid, key: "GID") }
            if let mode = entry.mode { builder.append(uint: mode, key: "MOD") }
            if let flags = entry.flags { builder.append(uint: flags, key: "FLG") }
            if let creation = entry.creation { builder.append(timespec: creation, key: "CTM") }
            if let modification = entry.modification {
                builder.append(timespec: modification, key: "MTM")
            }
            let blobs =
                entry.blobsBefore + (entry.data.map { [(key: "DAT", data: $0)] } ?? []) + entry.blobsAfter
            for blob in blobs { builder.append(blobSize: UInt64(blob.data.count), key: blob.key) }
            var header = try #require(builder.make())
            if let editEncoding = entry.editEncoding {
                var encoded = header.withAAEncodedData { Array($0) }
                editEncoding(&encoded)
                header = try #require(
                    encoded.withUnsafeBufferPointer { ArchiveHeader(withAAEncodedData: $0) })
            }
            try encode.writeHeader(header)
            for blob in blobs where !blob.data.isEmpty {
                try blob.data.withUnsafeBytes { try encode.writeBlob(key: .init(blob.key), from: $0) }
            }
        }
    }
    return sink.bytes
}

/// Extracts `archive` into `destination` on `volume`, returning what ended the
/// extract, or `nil` when it unpacked whole.
func extractFailure(
    _ archive: Data, into destination: URL,
    on volume: some ClipboardArchiveWritableVolume = ClipboardArchiveLocalVolume()
) -> Error? {
    ClipboardArchiveCodec.extract(
        from: ClipboardArchiveDataSource(bytes: archive), into: destination, on: volume,
        counted: Locked(0), pacingBytes: ClipboardStreamTuning.extractPacingBytes,
        onOutputAdvanced: nil)
}

// MARK: - A volume that counts and fails

/// The local volume, counting the directories it holds open and optionally
/// failing every write, or every rename, with one `errno`.
final class InterposedArchiveVolume: ClipboardArchiveWritableVolume, Sendable {
    private let base = ClipboardArchiveLocalVolume()
    private let writeFailure: Errno?
    private let renameFailure: Errno?

    private struct Directories {
        var open: Set<Int32> = []
        var most = 0
    }

    private let directories = Locked(Directories())

    /// The most directories that were open at once.
    var mostOpenDirectories: Int { directories.withLock { $0.most } }

    /// How many directories are open now.
    var openDirectoryCount: Int { directories.withLock { $0.open.count } }

    init(failingWritesWith writeFailure: Errno? = nil, failingRenamesWith renameFailure: Errno? = nil) {
        self.writeFailure = writeFailure
        self.renameFailure = renameFailure
    }

    func openDirectory(_ name: [UInt8], in directory: Int32) throws(Errno) -> Int32 {
        let descriptor = try base.openDirectory(name, in: directory)
        directories.withLock {
            $0.open.insert(descriptor)
            $0.most = max($0.most, $0.open.count)
        }
        return descriptor
    }

    func close(_ descriptor: Int32) {
        directories.withLock { _ = $0.open.remove(descriptor) }
        base.close(descriptor)
    }

    func write(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer) throws(Errno) -> Int {
        if let writeFailure { throw writeFailure }
        return try base.write(descriptor, from: buffer)
    }

    func status(of name: [UInt8], in directory: Int32) throws(Errno) -> stat {
        try base.status(of: name, in: directory)
    }

    func status(of descriptor: Int32) throws(Errno) -> stat { try base.status(of: descriptor) }

    func openFile(_ name: [UInt8], in directory: Int32) throws(Errno) -> Int32 {
        try base.openFile(name, in: directory)
    }

    func names(in directory: Int32) throws(Errno) -> [[UInt8]] { try base.names(in: directory) }

    func linkTarget(of name: [UInt8], in directory: Int32) throws(Errno) -> [UInt8] {
        try base.linkTarget(of: name, in: directory)
    }

    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws(Errno) -> Int {
        try base.read(descriptor, into: buffer)
    }

    func makeDirectory(_ name: [UInt8], in directory: Int32) throws(Errno) {
        try base.makeDirectory(name, in: directory)
    }

    func createFile(_ name: [UInt8], in directory: Int32) throws(Errno) -> Int32 {
        try base.createFile(name, in: directory)
    }

    func closeWritten(_ descriptor: Int32) throws(Errno) { try base.closeWritten(descriptor) }

    func makeSymlink(_ name: [UInt8], to target: [UInt8], in directory: Int32) throws(Errno) {
        try base.makeSymlink(name, to: target, in: directory)
    }

    func setGroup(_ group: gid_t, of target: ClipboardArchiveEntryTarget) throws(Errno) {
        try base.setGroup(group, of: target)
    }

    func setAttributes(
        _ attributes: ClipboardArchiveSettableAttributes, of target: ClipboardArchiveEntryTarget
    ) throws(Errno) {
        try base.setAttributes(attributes, of: target)
    }

    func remove(_ name: [UInt8], in directory: Int32, isDirectory: Bool) throws(Errno) {
        try base.remove(name, in: directory, isDirectory: isDirectory)
    }

    func rename(_ name: [UInt8], in directory: Int32, to newName: [UInt8], in newDirectory: Int32)
        throws(Errno)
    {
        if let renameFailure { throw renameFailure }
        try base.rename(name, in: directory, to: newName, in: newDirectory)
    }
}

// MARK: - Trees past PATH_MAX

/// A chain of `depth` directories named `name` under `root`, the deepest
/// holding `leaf` with `contents` — built through descriptors, since every
/// path-taking call refuses a path this long.
///
/// - Returns: the leaf's path relative to `root`.
@discardableResult
func makeDeepTree(
    under root: URL, depth: Int, name: String, leaf: String = "deep.txt", contents: Data
) throws -> String {
    var directory = open(root.path, O_RDONLY | O_DIRECTORY)
    try #require(directory >= 0)
    for _ in 0..<depth {
        try #require(mkdirat(directory, name, 0o755) == 0)
        let next = openat(directory, name, O_RDONLY | O_DIRECTORY)
        close(directory)
        try #require(next >= 0)
        directory = next
    }
    defer { close(directory) }
    let file = openat(directory, leaf, O_WRONLY | O_CREAT, 0o644)
    try #require(file >= 0)
    defer { close(file) }
    try #require(contents.withUnsafeBytes { write(file, $0.baseAddress, $0.count) } == contents.count)
    return (Array(repeating: name, count: depth) + [leaf]).joined(separator: "/")
}

/// The bytes of the file at `relativePath` under `root`, reached a component
/// at a time; `nil` when any component is missing.
func readThroughDescriptors(_ relativePath: String, under root: URL) -> Data? {
    var components = relativePath.split(separator: "/").map(String.init)
    let leaf = components.removeLast()
    var directory = open(root.path, O_RDONLY | O_DIRECTORY)
    guard directory >= 0 else { return nil }
    for component in components {
        let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        close(directory)
        guard next >= 0 else { return nil }
        directory = next
    }
    defer { close(directory) }
    let file = openat(directory, leaf, O_RDONLY | O_NOFOLLOW)
    guard file >= 0 else { return nil }
    defer { close(file) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(file, $0.baseAddress, $0.count) }
        guard count > 0 else { return count == 0 ? data : nil }
        data.append(contentsOf: buffer[..<count])
    }
}

/// The status of `path`, not following a symlink.
func linkStatus(_ path: String) throws -> stat {
    var status = stat()
    try #require(lstat(path, &status) == 0, "lstat \(path): \(String(cString: strerror(errno)))")
    return status
}

/// Whether two times are the same instant.
func sameInstant(_ a: timespec, _ b: timespec) -> Bool {
    a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec
}
