/// A regular file being created in its decmpfs-compressed form: the one way a compressed file is written.
///
/// Creating it writes its extended attributes and then its `com.apple.decmpfs` attribute into the new, empty
/// file; ``appendResourceFork(_:)`` writes the resource fork, through a ``ResourceForkWriter``; ``finish(_:)`` sets the
/// flags with `UF_COMPRESSED` in one write, confirms the system took the file compressed, then sets the mode and the times, which the flag write resets, and closes it.
/// Attributes before the flag is the order the kernel takes: the flag set first does not stick
/// (docs/research/2026-10-24-decmpfs-pass-through.md, finding 3).
///
/// Once the flag is set, any flag write without `UF_COMPRESSED` empties the file without an error (the
/// costs note, finding 3). The file's descriptor never leaves this type, whose only flag write carries
/// `UF_COMPRESSED`, so no other write can reach it.
public final class CompressedFile<FileSystem: MutableTreeFileSystem> {
    private let fileSystem: FileSystem
    /// The open file; nil once it is closed.
    private var descriptor: Int32?
    /// The logical size its `com.apple.decmpfs` attribute declares.
    public let logicalSize: UInt64
    /// The resource fork, written as it arrives.
    private var resourceFork: ResourceForkWriter

    /// Creates the regular file `name` in `directory` — failing when anything already has the name — and
    /// writes `extendedAttributes`, each dropped where the volume cannot hold it, then its compressed
    /// storage's attribute.
    ///
    /// - Parameters:
    ///   - name: The file's name in `directory`.
    ///   - directory: An open directory.
    ///   - attribute: The `com.apple.decmpfs` attribute.
    ///   - logicalSize: The logical size `attribute`'s header declares.
    ///   - resourceForkLength: The length of the resource fork ``appendResourceFork(_:)`` writes.
    ///   - extendedAttributes: The file's other extended attributes.
    ///   - fileSystem: The calls it makes.
    /// - Throws: `TreeFileSystemError` from the creation or a write; nothing it created then remains.
    public init(
        creating name: [UInt8], in directory: Int32, attribute: [UInt8], logicalSize: UInt64,
        resourceForkLength: UInt64, extendedAttributes: [ExtendedAttribute], on fileSystem: FileSystem
    ) throws(TreeFileSystemError) {
        self.fileSystem = fileSystem
        self.logicalSize = logicalSize
        resourceFork = ResourceForkWriter(length: resourceForkLength)
        let descriptor = try fileSystem.createFile(name, in: directory)
        do {
            for extended in extendedAttributes {
                try fileSystem.setExtendedAttribute(extended.name, to: extended.value, of: .descriptor(descriptor))
            }
            try fileSystem.setCompressedStorage(attribute, of: descriptor)
        } catch {
            fileSystem.close(descriptor)
            try? fileSystem.remove(name, in: directory, isDirectory: false)
            throw error
        }
        self.descriptor = descriptor
    }

    /// The status of the file, not yet closed: before ``finish(_:)``, or after one that failed before its close.
    public func status() throws(TreeFileSystemError) -> FileStatus {
        guard let descriptor else { preconditionFailure("the status of a finished file") }
        return try fileSystem.status(of: descriptor)
    }

    deinit {
        if let descriptor { fileSystem.close(descriptor) }
    }

    /// Appends `bytes` to the resource fork, within the length it was created with; only before ``finish(_:)``.
    ///
    /// - Throws: ``CompressedFileFailure``.
    public func appendResourceFork(_ bytes: UnsafeRawBufferPointer) throws(CompressedFileFailure) {
        guard let descriptor else { preconditionFailure("a resource fork appended to a finished file") }
        let held: Bool
        do {
            held = try resourceFork.append(bytes, to: descriptor, on: fileSystem)
        } catch {
            throw .system(error)
        }
        guard held else { throw .notCompressed(.resourceForkNotHeld) }
    }

    /// Sets the flags with `UF_COMPRESSED`, confirms the system took the file compressed, sets the mode
    /// and times of `attributes`, and closes the file.
    ///
    /// - Parameter attributes: What the file lands with; its flags carry no `UF_COMPRESSED` of their own.
    /// - Returns: The file's status once the system took it compressed.
    /// - Throws: ``CompressedFileFailure``; a failure before the close leaves the file open, for
    ///   ``status()``, until it is released.
    public func finish(_ attributes: TreeEntryAttributes) throws(CompressedFileFailure) -> FileStatus {
        guard let descriptor else { preconditionFailure("a file finished twice") }
        let status = try seal(descriptor, flags: attributes.flags ?? 0)
        // The flag write resets the modification time, so the times go after it.
        try settle(descriptor, attributes)
        self.descriptor = nil
        do {
            try fileSystem.closeWritten(descriptor)
        } catch {
            throw .system(error)
        }
        return status
    }

    /// The mode, then the times, of `attributes`, each in a write of its own that holds no flags.
    private func settle(_ descriptor: Int32, _ attributes: TreeEntryAttributes) throws(CompressedFileFailure) {
        do {
            try fileSystem.setAttributes(
                TreeEntryAttributes(permissions: attributes.permissions), of: .descriptor(descriptor))
            try fileSystem.setAttributes(
                TreeEntryAttributes(modificationTime: attributes.modificationTime, birthTime: attributes.birthTime),
                of: .descriptor(descriptor))
        } catch {
            throw .system(error)
        }
    }

    /// The flag write, then the status that confirms the system took the file compressed: `UF_COMPRESSED` set
    /// and `st_size` the attribute's logical size. Setting the flag is undefined in `chflags(2)`, so the file
    /// is used only once this holds. Once the flag sticks, `st_size` is the header's own value
    /// (docs/research/2026-10-24-decmpfs-pass-through.md, finding 1), so this confirms nothing about the
    /// content: a well-formed payload that decompresses short or wrong lands as sent.
    private func seal(_ descriptor: Int32, flags: UInt32) throws(CompressedFileFailure) -> FileStatus {
        do {
            try fileSystem.setCompressedFlags(flags, of: descriptor)
        } catch {
            throw .notCompressed(.flagRefused(error))
        }
        let status: FileStatus
        do {
            status = try fileSystem.status(of: descriptor)
        } catch {
            throw .system(error)
        }
        guard status.isCompressed, status.size >= 0, UInt64(status.size) == logicalSize else {
            throw .notCompressed(.unconfirmed(flags: status.flags, size: status.size, logicalSize: logicalSize))
        }
        return status
    }
}

/// Why a ``CompressedFile`` did not land.
public enum CompressedFileFailure: Error, Hashable, Sendable {
    /// A file-system call failed.
    case system(TreeFileSystemError)
    /// The volume did not take the file compressed, so it is not used; the same content lands if sent plain.
    case notCompressed(NotCompressed)
}

/// How the volume did not take a ``CompressedFile`` compressed.
public enum NotCompressed: Hashable, Sendable {
    /// The volume holds no resource fork, where the compressed bytes are.
    case resourceForkNotHeld
    /// The flag write failed: exFAT refuses `UF_COMPRESSED` with `EINVAL`.
    case flagRefused(TreeFileSystemError)
    /// After the flag write, the system did not take the file compressed: the flag did not stick, or `st_size`
    /// is not the logical size the attribute declares. It says nothing about the content, which `st_size`
    /// does not reflect.
    case unconfirmed(flags: UInt32, size: Int64, logicalSize: UInt64)
}
