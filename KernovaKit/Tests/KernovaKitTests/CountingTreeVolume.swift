import Darwin
import Foundation
import KernovaFileTree
import KernovaSynchronization
import System
import Testing

// MARK: - A volume that counts and fails

/// The local volume, counting the directories it holds open, and handing each
/// call that changes the volume to `before` first, which fails the call with
/// the `errno` it throws.
final class CountingTreeVolume: MutableTreeFileSystem {
    /// A call that changes the volume, about to be made.
    enum Call {
        case setMode(UInt32, name: [UInt8])
        case remove(name: [UInt8])
        case rename
    }

    private let base = POSIXTreeFileSystem()
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

    /// - Parameter before: runs ahead of every call that changes the volume.
    init(before: @escaping @Sendable (Call) throws(Errno) -> Void = { _ in }) {
        self.before = before
    }

    func openDirectory(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32 {
        held(try base.openDirectory(name, in: directory))
    }

    func openParent(of directory: Int32) throws(TreeFileSystemError) -> Int32 {
        held(try base.openParent(of: directory))
    }

    private func held(_ descriptor: Int32) -> Int32 {
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

    func status(of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> FileStatus {
        try base.status(of: name, in: directory)
    }

    func status(of descriptor: Int32) throws(TreeFileSystemError) -> FileStatus { try base.status(of: descriptor) }

    func openFile(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32 {
        try base.openFile(name, in: directory)
    }

    func names(in directory: Int32) throws(TreeFileSystemError) -> [[UInt8]] { try base.names(in: directory) }

    func linkTarget(of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> [UInt8] {
        try base.linkTarget(of: name, in: directory)
    }

    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws(TreeFileSystemError) -> Int {
        try base.read(descriptor, into: buffer)
    }

    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: Int64)
        throws(TreeFileSystemError) -> Int
    {
        try base.read(descriptor, into: buffer, at: offset)
    }

    func dataRun(in descriptor: Int32, from offset: Int64) throws(TreeFileSystemError) -> Range<Int64>? {
        try base.dataRun(in: descriptor, from: offset)
    }

    func extendedAttributeNames(of target: TreeEntryTarget) throws(TreeFileSystemError) -> [[UInt8]] {
        try base.extendedAttributeNames(of: target)
    }

    func extendedAttribute(_ name: [UInt8], of target: TreeEntryTarget, maxByteCount: Int)
        throws(TreeFileSystemError) -> [UInt8]?
    {
        try base.extendedAttribute(name, of: target, maxByteCount: maxByteCount)
    }

    func compressedStorage(of descriptor: Int32, maxByteCount: Int) throws(TreeFileSystemError) -> [UInt8]? {
        try base.compressedStorage(of: descriptor, maxByteCount: maxByteCount)
    }

    func resourceForkSize(of descriptor: Int32, showingCompression: Bool) throws(TreeFileSystemError) -> UInt64 {
        try base.resourceForkSize(of: descriptor, showingCompression: showingCompression)
    }

    func readResourceFork(
        _ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64, showingCompression: Bool
    ) throws(TreeFileSystemError) -> Int {
        try base.readResourceFork(descriptor, into: buffer, at: offset, showingCompression: showingCompression)
    }

    func setMode(_ mode: UInt32, of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) {
        try interpose(.setMode(mode, name: name))
        try base.setMode(mode, of: name, in: directory)
    }

    func remove(_ name: [UInt8], in directory: Int32, isDirectory: Bool) throws(TreeFileSystemError) {
        try interpose(.remove(name: name))
        try base.remove(name, in: directory, isDirectory: isDirectory)
    }

    func rename(_ name: [UInt8], in directory: Int32, to newName: [UInt8], in newDirectory: Int32)
        throws(TreeFileSystemError)
    {
        try interpose(.rename)
        try base.rename(name, in: directory, to: newName, in: newDirectory)
    }

    func renameReplacing(_ name: [UInt8], in directory: Int32, to newName: [UInt8], in newDirectory: Int32)
        throws(TreeFileSystemError)
    {
        try interpose(.rename)
        try base.renameReplacing(name, in: directory, to: newName, in: newDirectory)
    }

    func renamesExclusively(in directory: Int32) throws(TreeFileSystemError) -> Bool {
        try base.renamesExclusively(in: directory)
    }

    func makeDirectory(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) {
        try base.makeDirectory(name, in: directory)
    }

    func createFile(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32 {
        try base.createFile(name, in: directory)
    }

    func makeSymlink(_ name: [UInt8], to target: [UInt8], in directory: Int32) throws(TreeFileSystemError) {
        try base.makeSymlink(name, to: target, in: directory)
    }

    func write(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer, at offset: Int64)
        throws(TreeFileSystemError) -> Int
    {
        try base.write(descriptor, from: buffer, at: offset)
    }

    func setSize(of descriptor: Int32, to size: Int64) throws(TreeFileSystemError) {
        try base.setSize(of: descriptor, to: size)
    }

    func holeSize(of descriptor: Int32) -> Int? { base.holeSize(of: descriptor) }

    func punchHole(in descriptor: Int32, at offset: Int64, length: Int64) throws(TreeFileSystemError) {
        try base.punchHole(in: descriptor, at: offset, length: length)
    }

    func closeWritten(_ descriptor: Int32) throws(TreeFileSystemError) { try base.closeWritten(descriptor) }

    func setExtendedAttribute(_ name: [UInt8], to value: [UInt8], of target: TreeEntryTarget)
        throws(TreeFileSystemError)
    {
        try base.setExtendedAttribute(name, to: value, of: target)
    }

    func writeResourceFork(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer, at offset: UInt64)
        throws(TreeFileSystemError) -> Bool
    {
        try base.writeResourceFork(descriptor, from: buffer, at: offset)
    }

    func volumeStoresCompressedFiles(_ directory: Int32) throws(TreeFileSystemError) -> Bool {
        try base.volumeStoresCompressedFiles(directory)
    }

    func setCompressedStorage(_ attribute: [UInt8], of descriptor: Int32) throws(TreeFileSystemError) {
        try base.setCompressedStorage(attribute, of: descriptor)
    }

    func setCompressedFlags(_ flags: UInt32, of descriptor: Int32) throws(TreeFileSystemError) {
        try base.setCompressedFlags(flags, of: descriptor)
    }

    func setAttributes(_ attributes: TreeEntryAttributes, of target: TreeEntryTarget) throws(TreeFileSystemError) {
        try base.setAttributes(attributes, of: target)
    }

    func landingRefusal(of name: [UInt8], pathByteCount: Int) -> TreeFileSystemError? {
        base.landingRefusal(of: name, pathByteCount: pathByteCount)
    }

    private func interpose(_ call: Call) throws(TreeFileSystemError) {
        do {
            try before(call)
        } catch {
            throw TreeFileSystemError(code: error.rawValue)
        }
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
