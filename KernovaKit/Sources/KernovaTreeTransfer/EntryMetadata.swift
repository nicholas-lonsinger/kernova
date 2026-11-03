import KernovaFileTree
import KernovaWire

/// What an entry lands with besides its contents: its extended attributes, then its mode, flags and times.
struct EntryMetadata: Sendable {
    struct ExtendedAttribute: Sendable {
        let name: [UInt8]
        let value: [UInt8]
    }

    let extendedAttributes: [ExtendedAttribute]
    let attributes: TreeEntryAttributes

    init(_ header: EntryHeader) {
        extendedAttributes = header.xattrs.map { ExtendedAttribute(name: Array($0.name), value: Array($0.value)) }
        attributes = TreeEntryAttributes(
            permissions: header.mode,
            // A new entry has no flags, so none to set is nothing to ask a volume that may refuse flags for.
            flags: header.darwinFlags == 0 ? nil : header.darwinFlags,
            modificationTime: header.hasModificationTime ? FileTime(header.modificationTime) : nil,
            birthTime: header.hasBirthTime ? FileTime(header.birthTime) : nil)
    }

    /// Applies the metadata to `target`: the extended attributes first, so a mode withholding the owner's
    /// write cannot keep one from landing.
    func apply<FileSystem: MutableTreeFileSystem>(to target: TreeEntryTarget, on fileSystem: FileSystem)
        throws(TreeFileSystemError)
    {
        for attribute in extendedAttributes {
            try fileSystem.setExtendedAttribute(attribute.name, to: attribute.value, of: target)
        }
        try fileSystem.setAttributes(attributes, of: target)
    }
}

extension FileTime {
    init(_ time: Kernova_V2_Timespec) {
        self.init(seconds: time.seconds, nanoseconds: Int64(time.nanoseconds))
    }
}
