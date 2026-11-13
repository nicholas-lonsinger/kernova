#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import KernovaFileTree

/// This machine's volumes through `POSIXTreeFileSystem`, but for the volume behaviors a test stands in for.
public struct InterposedFileSystem: MutableTreeFileSystem {
    /// How the volume renames without replacing.
    public enum ExclusiveRename: Sendable {
        /// As the volume does.
        case asTheVolume
        /// The volume says it cannot, as exFAT does on Darwin.
        case unsupported
        /// The volume says it can, and refuses the flag `ENOTSUP`, as a Linux file system without
        /// `RENAME_NOREPLACE` does.
        case refused
    }

    let base = POSIXTreeFileSystem()
    /// A flag write leaves the flags as they are: the result the confirmation after `UF_COMPRESSED` exists to
    /// catch.
    public var dropsCompressedFlags: Bool
    /// How the volume renames without replacing.
    public var exclusiveRename: ExclusiveRename
    /// Every write fails with this errno, as a full volume fails it `ENOSPC`.
    public var writeFailure: Int32?

    /// The volumes as they are, but for the behaviors given.
    public init(
        dropsCompressedFlags: Bool = false, exclusiveRename: ExclusiveRename = .asTheVolume, writeFailure: Int32? = nil
    ) {
        self.dropsCompressedFlags = dropsCompressedFlags
        self.exclusiveRename = exclusiveRename
        self.writeFailure = writeFailure
    }

    /// Nothing when `dropsCompressedFlags` is set; otherwise as the volume does.
    public func setCompressedFlags(_ flags: UInt32, of descriptor: Int32) throws(TreeFileSystemError) {
        if !dropsCompressedFlags { try base.setCompressedFlags(flags, of: descriptor) }
    }

    /// As the volume does.
    public func status(of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> FileStatus {
        try base.status(of: name, in: directory)
    }
    /// As the volume does.
    public func status(of descriptor: Int32) throws(TreeFileSystemError) -> FileStatus {
        try base.status(of: descriptor)
    }
    /// As the volume does.
    public func openDirectory(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32 {
        try base.openDirectory(name, in: directory)
    }
    /// As the volume does.
    public func openParent(of directory: Int32) throws(TreeFileSystemError) -> Int32 {
        try base.openParent(of: directory)
    }
    /// As the volume does.
    public func openFile(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32 {
        try base.openFile(name, in: directory)
    }
    /// As the volume does.
    public func names(in directory: Int32) throws(TreeFileSystemError) -> [[UInt8]] { try base.names(in: directory) }
    /// As the volume does.
    public func linkTarget(of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> [UInt8] {
        try base.linkTarget(of: name, in: directory)
    }
    /// As the volume does.
    public func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws(TreeFileSystemError)
        -> Int
    {
        try base.read(descriptor, into: buffer)
    }
    /// As the volume does.
    public func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: Int64)
        throws(TreeFileSystemError) -> Int
    {
        try base.read(descriptor, into: buffer, at: offset)
    }
    /// As the volume does.
    public func dataRun(in descriptor: Int32, from offset: Int64) throws(TreeFileSystemError) -> Range<Int64>? {
        try base.dataRun(in: descriptor, from: offset)
    }
    /// As the volume does.
    public func extendedAttributeNames(of target: TreeEntryTarget) throws(TreeFileSystemError) -> [[UInt8]] {
        try base.extendedAttributeNames(of: target)
    }
    /// As the volume does.
    public func extendedAttribute(_ name: [UInt8], of target: TreeEntryTarget, maxByteCount: Int)
        throws(TreeFileSystemError) -> [UInt8]?
    {
        try base.extendedAttribute(name, of: target, maxByteCount: maxByteCount)
    }
    /// As the volume does.
    public func compressedStorage(of descriptor: Int32, maxByteCount: Int) throws(TreeFileSystemError) -> [UInt8]? {
        try base.compressedStorage(of: descriptor, maxByteCount: maxByteCount)
    }
    /// As the volume does.
    public func resourceForkSize(of descriptor: Int32, showingCompression: Bool) throws(TreeFileSystemError)
        -> UInt64
    {
        try base.resourceForkSize(of: descriptor, showingCompression: showingCompression)
    }
    /// As the volume does.
    public func readResourceFork(
        _ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64, showingCompression: Bool
    ) throws(TreeFileSystemError) -> Int {
        try base.readResourceFork(descriptor, into: buffer, at: offset, showingCompression: showingCompression)
    }
    /// As the volume does.
    public func close(_ descriptor: Int32) { base.close(descriptor) }
    /// As the volume does.
    public func setMode(_ mode: UInt32, of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) {
        try base.setMode(mode, of: name, in: directory)
    }
    /// As the volume does.
    public func remove(_ name: [UInt8], in directory: Int32, isDirectory: Bool) throws(TreeFileSystemError) {
        try base.remove(name, in: directory, isDirectory: isDirectory)
    }
    /// `ENOTSUP` unless `exclusiveRename` is `.asTheVolume`; otherwise as the volume does.
    public func rename(_ name: [UInt8], in directory: Int32, to newName: [UInt8], in newDirectory: Int32)
        throws(TreeFileSystemError)
    {
        if exclusiveRename != .asTheVolume { throw TreeFileSystemError(code: ENOTSUP) }
        try base.rename(name, in: directory, to: newName, in: newDirectory)
    }
    /// As the volume does.
    public func renameReplacing(_ name: [UInt8], in directory: Int32, to newName: [UInt8], in newDirectory: Int32)
        throws(TreeFileSystemError)
    {
        try base.renameReplacing(name, in: directory, to: newName, in: newDirectory)
    }
    /// As `exclusiveRename` says.
    public func renamesExclusively(in directory: Int32) throws(TreeFileSystemError) -> Bool {
        switch exclusiveRename {
        case .asTheVolume: try base.renamesExclusively(in: directory)
        case .unsupported: false
        case .refused: true
        }
    }
    /// As the volume does.
    public func makeDirectory(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) {
        try base.makeDirectory(name, in: directory)
    }
    /// As the volume does.
    public func createFile(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32 {
        try base.createFile(name, in: directory)
    }
    /// As the volume does.
    public func openFileForAppending(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32 {
        try base.openFileForAppending(name, in: directory)
    }
    /// As the volume does.
    public func makeSymlink(_ name: [UInt8], to target: [UInt8], in directory: Int32) throws(TreeFileSystemError) {
        try base.makeSymlink(name, to: target, in: directory)
    }
    /// Fails with `writeFailure` when it is set; otherwise as the volume does.
    public func write(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer, at offset: Int64)
        throws(TreeFileSystemError) -> Int
    {
        if let writeFailure { throw TreeFileSystemError(code: writeFailure) }
        return try base.write(descriptor, from: buffer, at: offset)
    }
    /// As the volume does.
    public func setSize(of descriptor: Int32, to size: Int64) throws(TreeFileSystemError) {
        try base.setSize(of: descriptor, to: size)
    }
    /// As the volume does.
    public func holeSize(of descriptor: Int32) -> Int? { base.holeSize(of: descriptor) }
    /// As the volume does.
    public func punchHole(in descriptor: Int32, at offset: Int64, length: Int64) throws(TreeFileSystemError) {
        try base.punchHole(in: descriptor, at: offset, length: length)
    }
    /// As the volume does.
    public func closeWritten(_ descriptor: Int32) throws(TreeFileSystemError) { try base.closeWritten(descriptor) }
    /// As the volume does.
    public func setExtendedAttribute(_ name: [UInt8], to value: [UInt8], of target: TreeEntryTarget)
        throws(TreeFileSystemError)
    {
        try base.setExtendedAttribute(name, to: value, of: target)
    }
    /// As the volume does.
    public func writeResourceFork(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer, at offset: UInt64)
        throws(TreeFileSystemError) -> Bool
    {
        try base.writeResourceFork(descriptor, from: buffer, at: offset)
    }
    /// As the volume does.
    public func volumeStoresCompressedFiles(_ directory: Int32) throws(TreeFileSystemError) -> Bool {
        try base.volumeStoresCompressedFiles(directory)
    }
    /// As the volume does.
    public func setCompressedStorage(_ attribute: [UInt8], of descriptor: Int32) throws(TreeFileSystemError) {
        try base.setCompressedStorage(attribute, of: descriptor)
    }
    /// As the volume does.
    public func setAttributes(_ attributes: TreeEntryAttributes, of target: TreeEntryTarget)
        throws(TreeFileSystemError)
    {
        try base.setAttributes(attributes, of: target)
    }
    /// As the volume does.
    public func landingRefusal(of name: [UInt8], pathByteCount: Int) -> TreeFileSystemError? {
        base.landingRefusal(of: name, pathByteCount: pathByteCount)
    }
}
#endif
