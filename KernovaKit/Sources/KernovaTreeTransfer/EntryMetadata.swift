import KernovaContainer
import KernovaFileTree
import KernovaWire

/// What an entry lands with besides its contents: its extended attributes, then its mode, flags and times.
struct EntryMetadata: Sendable {
    let extendedAttributes: [ExtendedAttribute]
    let attributes: TreeEntryAttributes

    /// The metadata of `entry`, whose header keeps the format's rules, so no flag or extended attribute
    /// lands that the format does not carry.
    init(_ entry: ValidatedEntry) {
        let header = entry.header
        extendedAttributes = header.xattrs.map { ExtendedAttribute(name: Array($0.name), value: Array($0.value)) }
        attributes = TreeEntryAttributes(
            permissions: header.type == .data ? Self.dataPermissions : header.mode,
            // A new entry has no flags, so none to set is nothing to ask a volume that may refuse flags for.
            flags: header.darwinFlags == 0 ? nil : header.darwinFlags,
            modificationTime: header.hasModificationTime ? FileTime(header.modificationTime) : nil,
            birthTime: header.hasBirthTime ? FileTime(header.birthTime) : nil)
    }

    /// The mode an INLINE representation's DATA entry lands with: the format carries none for it
    /// (`ValidatedEntry` admits a DATA header only bare), so its owner alone reads and writes it.
    static let dataPermissions: UInt32 = 0o600

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
