import AppleArchive
import Darwin
import Foundation
import KernovaSynchronization
import System
import Testing

@testable import KernovaKit

/// Extracts `archive` into `destination`, returning what ended the extract,
/// or `nil` when it unpacked whole.
func extractFailure(_ archive: Data, into destination: URL) -> Error? {
    ClipboardArchiveCodec.extract(
        from: ClipboardArchiveDataSource(bytes: archive), into: destination,
        counted: Locked(0), pacingBytes: ClipboardStreamTuning.extractPacingBytes,
        onOutputAdvanced: nil)
}

// MARK: - A volume that counts and fails

/// The local volume, counting the directories it holds open, and handing each
/// call that changes the volume to `before` first, which fails the call with
/// the `errno` it throws.
final class InterposedArchiveVolume: ClipboardArchiveWritableVolume {
    /// A call that changes the volume, about to be made.
    enum Call {
        case setMode(mode_t, name: [UInt8])
        case remove(name: [UInt8])
        case rename
    }

    private let base = ClipboardArchiveLocalVolume()
    private let before: @Sendable (Call) throws(Errno) -> Void

    /// Directories the volume opened and has not closed.
    private struct Held {
        var open: Set<Int32> = []
        var most = 0
    }

    private let directories = Locked(Held())

    /// The most directories that were open at once.
    var mostOpenDirectories: Int { directories.withLock { $0.most } }

    /// How many directories are open now.
    var openDirectoryCount: Int { directories.withLock { $0.open.count } }

    /// - Parameters:
    ///   - renameFailure: what every rename fails with.
    ///   - before: runs ahead of every call that changes the volume.
    init(
        failingRenamesWith renameFailure: Errno? = nil,
        before: @escaping @Sendable (Call) throws(Errno) -> Void = { _ in }
    ) {
        self.before = { call throws(Errno) in
            if case .rename = call, let renameFailure { throw renameFailure }
            try before(call)
        }
    }

    func openDirectory(_ name: [UInt8], in directory: Int32) throws(Errno) -> Int32 {
        let descriptor = try base.openDirectory(name, in: directory)
        directories.withLock { held in
            held.open.insert(descriptor)
            held.most = max(held.most, held.open.count)
        }
        return descriptor
    }

    func close(_ descriptor: Int32) {
        // Counted closed ahead of the close that frees its number for another
        // open.
        directories.withLock { _ = $0.open.remove(descriptor) }
        base.close(descriptor)
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

    func setMode(_ mode: mode_t, of name: [UInt8], in directory: Int32) throws(Errno) {
        try before(.setMode(mode, name: name))
        try base.setMode(mode, of: name, in: directory)
    }

    func remove(_ name: [UInt8], in directory: Int32, isDirectory: Bool) throws(Errno) {
        try before(.remove(name: name))
        try base.remove(name, in: directory, isDirectory: isDirectory)
    }

    func rename(_ name: [UInt8], in directory: Int32, to newName: [UInt8], in newDirectory: Int32)
        throws(Errno)
    {
        try before(.rename)
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
