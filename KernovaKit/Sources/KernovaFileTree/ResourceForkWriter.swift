/// A resource fork written in order, in positional pieces, up to the length it was declared at: the one way a
/// fork is written in more than one call.
public struct ResourceForkWriter: Sendable {
    /// The fork's declared length.
    public let length: UInt64
    /// The bytes written so far.
    public private(set) var byteCount: UInt64 = 0

    /// A writer for a fork of `length` bytes, none written yet.
    public init(length: UInt64) {
        self.length = length
    }

    /// Writes `bytes` into the resource fork of the open regular file `descriptor`, after the bytes written so
    /// far; together they fit in ``length``. A first piece shorter than ``length`` is preceded by
    /// ``preExtend(_:on:)``.
    ///
    /// - Returns: `false`, having written nothing, when the volume or the OS holds no resource fork there.
    /// - Throws: `TreeFileSystemError` from a write.
    public mutating func append<FileSystem: MutableTreeFileSystem>(
        _ bytes: UnsafeRawBufferPointer, to descriptor: Int32, on fileSystem: FileSystem
    ) throws(TreeFileSystemError) -> Bool {
        precondition(UInt64(bytes.count) <= length - byteCount, "a resource fork written past its declared length")
        guard !bytes.isEmpty else { return true }
        if byteCount == 0, UInt64(bytes.count) < length {
            guard try preExtend(descriptor, on: fileSystem) else { return false }
        }
        guard try fileSystem.writeResourceFork(descriptor, from: bytes, at: byteCount) else { return false }
        byteCount += UInt64(bytes.count)
        return true
    }

    /// Writes one zero byte at the fork's last offset, which a later piece overwrites, so the fork has its
    /// whole length before the pieces fill it.
    ///
    /// On APFS a fork grown piece by piece takes more blocks than the same fork written whole, and one
    /// extended to its length first takes exactly as many
    /// (docs/research/2026-11-03-pass-through-gate.md, finding 2;
    /// docs/research/2026-11-03-fork-pre-extension.md). No vendor documents that allocation, so it decides
    /// only the blocks the fork takes, never its content: if the volume ignores it, the fork lands correct and
    /// larger, and a landing that fails before the pieces fill the fork is discarded whole, as any failed
    /// landing is.
    private func preExtend<FileSystem: MutableTreeFileSystem>(_ descriptor: Int32, on fileSystem: FileSystem)
        throws(TreeFileSystemError) -> Bool
    {
        var zero: UInt8 = 0
        return try withUnsafeBytes(of: &zero) { byte throws(TreeFileSystemError) in
            try fileSystem.writeResourceFork(descriptor, from: byte, at: length - 1)
        }
    }
}
