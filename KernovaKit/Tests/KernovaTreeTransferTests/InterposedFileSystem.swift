#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import KernovaFileTree

/// This machine's volumes through ``POSIXTreeFileSystem``, but for the volume behaviors a test stands in for.
struct InterposedFileSystem: MutableTreeFileSystem {
    /// How the volume renames without replacing.
    enum ExclusiveRename {
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
    var dropsCompressedFlags = false
    var exclusiveRename = ExclusiveRename.asTheVolume

    func setCompressedFlags(_ flags: UInt32, of descriptor: Int32) throws(TreeFileSystemError) {
        if !dropsCompressedFlags { try base.setCompressedFlags(flags, of: descriptor) }
    }

    func status(of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> FileStatus {
        try base.status(of: name, in: directory)
    }
    func status(of descriptor: Int32) throws(TreeFileSystemError) -> FileStatus { try base.status(of: descriptor) }
    func openDirectory(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32 {
        try base.openDirectory(name, in: directory)
    }
    func openParent(of directory: Int32) throws(TreeFileSystemError) -> Int32 { try base.openParent(of: directory) }
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
    func close(_ descriptor: Int32) { base.close(descriptor) }
    func setMode(_ mode: UInt32, of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) {
        try base.setMode(mode, of: name, in: directory)
    }
    func remove(_ name: [UInt8], in directory: Int32, isDirectory: Bool) throws(TreeFileSystemError) {
        try base.remove(name, in: directory, isDirectory: isDirectory)
    }
    func rename(_ name: [UInt8], in directory: Int32, to newName: [UInt8], in newDirectory: Int32)
        throws(TreeFileSystemError)
    {
        if exclusiveRename != .asTheVolume { throw TreeFileSystemError(code: ENOTSUP) }
        try base.rename(name, in: directory, to: newName, in: newDirectory)
    }
    func renameReplacing(_ name: [UInt8], in directory: Int32, to newName: [UInt8], in newDirectory: Int32)
        throws(TreeFileSystemError)
    {
        try base.renameReplacing(name, in: directory, to: newName, in: newDirectory)
    }
    func renamesExclusively(in directory: Int32) throws(TreeFileSystemError) -> Bool {
        switch exclusiveRename {
        case .asTheVolume: try base.renamesExclusively(in: directory)
        case .unsupported: false
        case .refused: true
        }
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
    func setAttributes(_ attributes: TreeEntryAttributes, of target: TreeEntryTarget) throws(TreeFileSystemError) {
        try base.setAttributes(attributes, of: target)
    }
    func landingRefusal(of name: [UInt8], pathByteCount: Int) -> TreeFileSystemError? {
        base.landingRefusal(of: name, pathByteCount: pathByteCount)
    }
}
#endif
