#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// The rules a container's records keep, past their framing: one enforcement path, which the encoder runs as
/// it writes and the decoder as it reads, so neither side can produce what the other refuses.
struct ContainerGrammar {
    /// What an admitted header is.
    enum Entry {
        case directory
        /// A file or INLINE data; `complete` when it declares no bytes, so no chunk follows.
        case file(complete: Bool)
        case symlink
    }

    /// The longest name a POSIX file system takes, `NAME_MAX`.
    static let maxNameByteCount = 255

    /// The extended attribute a decmpfs entry carries as its storage, never in its list.
    static let decmpfsAttributeName = Data("com.apple.decmpfs".utf8)

    let acceptance: ContainerAcceptance

    /// The directories entered and not yet left; an entry at depth d lies inside the first d of them.
    private(set) var enteredDirectories = 0
    /// The bytes the current entry still owes, or nil when no entry owes any.
    private(set) var remainingBytes: UInt64?
    /// Whether the current entry's storage is LZ4, so its chunks may be LZ4 blocks.
    private(set) var currentIsLZ4 = false
    private(set) var counted = ContainerError.Counts(entries: 0, bytes: 0)
    private var declaredBytes: UInt64 = 0
    private(set) var ended = false

    init(acceptance: ContainerAcceptance) {
        self.acceptance = acceptance
    }

    /// Admits `header`, returning how many directories to leave before it and what it is.
    mutating func admit(_ header: EntryHeader) throws(ContainerError) -> (leaving: Int, entry: Entry) {
        try requireBetweenEntries()
        let leaving = try place(header)
        let size = try storageSize(of: header)
        try checkMetadata(of: header)
        if size > acceptance.byteCeiling - declaredBytes {
            throw .exceedsByteCeiling(declared: declaredBytes &+ size, ceiling: acceptance.byteCeiling)
        }
        declaredBytes += size
        counted.entries += 1
        enteredDirectories = Int(header.depth)
        switch header.type {
        case .directory:
            enteredDirectories += 1
            return (leaving, .directory)
        case .symlink:
            return (leaving, .symlink)
        default:
            if case .lz4 = header.storage { currentIsLZ4 = true } else { currentIsLZ4 = false }
            remainingBytes = size == 0 ? nil : size
            return (leaving, .file(complete: size == 0))
        }
    }

    /// Admits a chunk carrying `count` bytes of the current entry, returning whether the entry is now complete.
    mutating func admitChunk(count: UInt64, lz4: Bool) throws(ContainerError) -> Bool {
        guard !ended else { throw .bytesAfterEnd }
        guard let remaining = remainingBytes else { throw .chunkOutsideEntry }
        guard !lz4 || currentIsLZ4 else { throw .lz4ChunkOutsideLZ4Storage }
        guard count > 0 else { throw .emptyChunk }
        guard count <= remaining else { throw .chunkPastEntrySize(count: count, remaining: remaining) }
        counted.bytes += count
        remainingBytes = remaining == count ? nil : remaining - count
        return remainingBytes == nil
    }

    /// Admits the end record, returning how many directories to leave before the end.
    mutating func admitEnd(_ end: EndRecord) throws(ContainerError) -> Int {
        try requireBetweenEntries()
        guard counted.entries > 0 else { throw .noEntry }
        let stated = ContainerError.Counts(entries: end.entries, bytes: end.bytes)
        guard stated == counted else { throw .endCountsMismatch(stated: stated, counted: counted) }
        ended = true
        defer { enteredDirectories = 0 }
        return enteredDirectories
    }

    private func requireBetweenEntries() throws(ContainerError) {
        guard !ended else { throw .bytesAfterEnd }
        if let remainingBytes { throw .entryIncomplete(remaining: remainingBytes) }
    }

    /// The directories to leave before `header`, whose parent is then the innermost one entered.
    private func place(_ header: EntryHeader) throws(ContainerError) -> Int {
        switch header.type {
        case .data, .file, .directory, .symlink: break
        case .unspecified, .UNRECOGNIZED: throw .unknownEntryType
        }
        if counted.entries == 0 {
            guard header.depth == 0 else { throw .firstEntryNotAtRoot(depth: header.depth) }
            return 0
        }
        guard header.depth > 0 else { throw .secondRootEntry }
        guard Int(header.depth) <= enteredDirectories else {
            throw .depthBeyondParent(depth: header.depth, enteredDirectories: enteredDirectories)
        }
        return enteredDirectories - Int(header.depth)
    }

    /// The bytes `header`'s chunks carry, once its storage is checked against its type and the acceptance.
    private func storageSize(of header: EntryHeader) throws(ContainerError) -> UInt64 {
        switch (header.type, header.storage) {
        case (.data, .plain(let plain)?), (.file, .plain(let plain)?):
            return plain.size
        case (.data, .lz4(let lz4)?), (.file, .lz4(let lz4)?):
            guard acceptance.acceptsLZ4 else { throw .lz4NotAccepted }
            return lz4.size
        case (.file, .decmpfs(let decmpfs)?):
            let attributeHeader: DecmpfsHeader
            do {
                attributeHeader = try DecmpfsHeader(attribute: decmpfs.attribute)
            } catch {
                throw .malformedDecmpfsAttribute(error)
            }
            guard acceptance.decmpfsTypes.contains(attributeHeader.compressionType) else {
                throw .decmpfsTypeNotAccepted(attributeHeader.compressionType)
            }
            return decmpfs.resourceForkSize
        case (.directory, nil), (.symlink, nil):
            return 0
        default:
            throw .storageNotAllowed(header.type)
        }
    }

    private func checkMetadata(of header: EntryHeader) throws(ContainerError) {
        if header.type == .data {
            let bare =
                header.name.isEmpty && header.mode == 0 && header.darwinFlags == 0 && !header.hasModificationTime
                && !header.hasBirthTime && header.xattrs.isEmpty && header.symlinkTarget.isEmpty
            guard bare else { throw .dataEntryNotBare }
            return
        }
        guard Self.isValidName(header.name) else { throw .invalidName }
        if header.type == .symlink {
            guard !header.symlinkTarget.isEmpty, !header.symlinkTarget.contains(0) else {
                throw .invalidSymlinkTarget
            }
        } else {
            guard header.symlinkTarget.isEmpty else { throw .invalidSymlinkTarget }
        }
        guard !header.xattrs.contains(where: { $0.name == Self.decmpfsAttributeName }) else {
            throw .decmpfsAttributeOutsideStorage
        }
    }

    /// Whether `name` is one path component a POSIX file system takes as it is.
    static func isValidName(_ name: Data) -> Bool {
        guard !name.isEmpty, name.count <= maxNameByteCount else { return false }
        guard name != Data([0x2E]), name != Data([0x2E, 0x2E]) else { return false }
        return !name.contains(0x2F) && !name.contains(0)
    }
}
