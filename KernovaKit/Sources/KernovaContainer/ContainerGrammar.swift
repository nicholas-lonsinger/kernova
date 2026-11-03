#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire
import SwiftProtobuf

/// The rules a container's records keep, past their framing: one enforcement path, which the encoder runs as
/// it writes and the decoder as it reads, so neither side can produce what the other refuses.
struct ContainerGrammar {
    /// What an admitted header is.
    enum Entry {
        case directory
        /// A file or INLINE data; `complete` when it carries no bytes, so no chunk follows.
        case file(complete: Bool)
        case symlink
    }

    /// The longest name a POSIX file system takes, `NAME_MAX`; extended attribute names share it
    /// (`XATTR_MAXNAMELEN` on Darwin, `XATTR_NAME_MAX` on Linux).
    static let maxNameByteCount = 255

    /// The longest symlink target: Darwin's `PATH_MAX` of 1,024 bytes (`sys/syslimits.h`) less the NUL that
    /// ends it, beyond which `symlink(2)` fails with `ENAMETOOLONG`. Darwin's is the smallest of the supported
    /// guest and host OSes, so every writer can create any target the format carries.
    static let maxSymlinkTargetByteCount = 1_023

    /// The permission bits, `07777`.
    static let maxMode: UInt32 = 0o7777

    static let maxNanoseconds: UInt32 = 999_999_999

    /// The `darwin_flags` an entry may carry: the owner flags `UF_NODUMP` (0x1), `UF_OPAQUE` (0x8) and
    /// `UF_HIDDEN` (0x8000), as Darwin's `sys/stat.h` numbers them. Every other bit is refused:
    /// `UF_IMMUTABLE`, `UF_APPEND` and `UF_DATAVAULT` block removal of the landed tree or need an entitlement,
    /// the superuser and synthetic flags need privilege the receiver lacks, `UF_COMPRESSED` is implied by
    /// decmpfs storage alone, and `UF_TRACKED` marks a document ID that does not travel.
    static let allowedDarwinFlags: UInt32 = 0x0000_8009

    /// The extended attributes the format carries, by exact name: Finder tags and the resource fork.
    static let allowedXattrNames: Set<Data> = [
        Data("com.apple.metadata:_kMDItemUserTags".utf8), resourceForkName,
    ]

    /// The extended attribute namespace the format carries whole: Linux's `user.*`.
    static let allowedXattrPrefix = Data("user.".utf8)

    /// The resource fork, which an entry with decmpfs storage carries as its chunks instead.
    static let resourceForkName = Data("com.apple.ResourceFork".utf8)

    let acceptance: ContainerAcceptance

    /// The directories entered and not yet left; an entry at depth d lies inside the first d of them.
    private(set) var enteredDirectories = 0
    /// The bytes the current entry still owes, or nil when no entry owes any.
    private(set) var remainingBytes: UInt64?
    /// Whether the current entry's storage is LZ4, so its chunks may be LZ4 blocks.
    private(set) var currentIsLZ4 = false
    private(set) var counted = ContainerError.Counts(entries: 0, bytes: 0)
    /// The logical bytes the entries so far land, which the byte ceiling bounds.
    private var landedBytes: UInt64 = 0
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
        if size.landed > acceptance.byteCeiling - landedBytes {
            throw .exceedsByteCeiling(declared: landedBytes &+ size.landed, ceiling: acceptance.byteCeiling)
        }
        landedBytes += size.landed
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
            remainingBytes = size.carried == 0 ? nil : size.carried
            return (leaving, .file(complete: size.carried == 0))
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
        guard end.unknownFields.data.isEmpty else { throw .unknownFields }
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
            guard header.type == Self.rootType(of: acceptance.storage) else {
                throw .rootTypeMismatch(header.type, expected: acceptance.storage)
            }
            return 0
        }
        guard header.type != .data else { throw .dataEntryNotRoot }
        guard header.depth > 0 else { throw .secondRootEntry }
        guard Int(header.depth) <= enteredDirectories else {
            throw .depthBeyondParent(depth: header.depth, enteredDirectories: enteredDirectories)
        }
        return enteredDirectories - Int(header.depth)
    }

    /// The root entry's type a representation of `storage` sends, or nil for a storage nothing sends.
    static func rootType(of storage: Representation.Storage) -> EntryHeader.TypeEnum? {
        switch storage {
        case .inline: .data
        case .file: .file
        case .folder: .directory
        case .unspecified, .UNRECOGNIZED: nil
        }
    }

    /// The bytes `header`'s chunks carry and the logical bytes it lands, once its storage is checked against
    /// its type and the acceptance. A decmpfs file lands the larger of its attribute's uncompressed size and
    /// its resource fork, so neither can pass the ceiling.
    private func storageSize(of header: EntryHeader) throws(ContainerError) -> (carried: UInt64, landed: UInt64) {
        switch (header.type, header.storage) {
        case (.data, .plain(let plain)?), (.file, .plain(let plain)?):
            guard plain.unknownFields.data.isEmpty else { throw .unknownFields }
            return (plain.size, plain.size)
        case (.data, .lz4(let lz4)?), (.file, .lz4(let lz4)?):
            guard lz4.unknownFields.data.isEmpty else { throw .unknownFields }
            guard acceptance.acceptsLZ4 else { throw .lz4NotAccepted }
            return (lz4.size, lz4.size)
        case (.file, .decmpfs(let decmpfs)?):
            guard decmpfs.unknownFields.data.isEmpty else { throw .unknownFields }
            let attributeHeader: DecmpfsHeader
            do {
                attributeHeader = try DecmpfsHeader(attribute: decmpfs.attribute)
            } catch {
                throw .malformedDecmpfsAttribute(error)
            }
            guard acceptance.decmpfsTypes.contains(attributeHeader.compressionType) else {
                throw .decmpfsTypeNotAccepted(attributeHeader.compressionType)
            }
            return (decmpfs.resourceForkSize, max(decmpfs.resourceForkSize, attributeHeader.uncompressedSize))
        case (.directory, nil), (.symlink, nil):
            return (0, 0)
        default:
            throw .storageNotAllowed(header.type)
        }
    }

    private func checkMetadata(of header: EntryHeader) throws(ContainerError) {
        guard header.unknownFields.data.isEmpty else { throw .unknownFields }
        if header.type == .data {
            let bare =
                header.depth == 0 && header.name.isEmpty && header.mode == 0 && header.darwinFlags == 0
                && !header.hasModificationTime && !header.hasBirthTime && header.xattrs.isEmpty
                && header.symlinkTarget.isEmpty
            guard bare else { throw .dataEntryNotBare }
            return
        }
        guard Self.isValidName(header.name) else { throw .invalidName }
        guard header.mode <= Self.maxMode else { throw .modeOutOfRange(header.mode) }
        guard header.darwinFlags & ~Self.allowedDarwinFlags == 0 else {
            throw .darwinFlagsNotAllowed(header.darwinFlags & ~Self.allowedDarwinFlags)
        }
        for time in [header.modificationTime, header.birthTime] {
            guard time.unknownFields.data.isEmpty else { throw .unknownFields }
            guard time.nanoseconds <= Self.maxNanoseconds else { throw .nanosecondsOutOfRange(time.nanoseconds) }
        }
        if header.type == .symlink {
            let target = header.symlinkTarget
            guard !target.isEmpty, target.count <= Self.maxSymlinkTargetByteCount, !target.contains(0) else {
                throw .invalidSymlinkTarget
            }
        } else {
            guard header.symlinkTarget.isEmpty else { throw .invalidSymlinkTarget }
        }
        try checkXattrs(of: header)
    }

    private func checkXattrs(of header: EntryHeader) throws(ContainerError) {
        var names = Set<Data>()
        let decmpfs: Bool
        if case .decmpfs = header.storage { decmpfs = true } else { decmpfs = false }
        for xattr in header.xattrs {
            guard xattr.unknownFields.data.isEmpty else { throw .unknownFields }
            let name = xattr.name
            guard !name.isEmpty, name.count <= Self.maxNameByteCount, !name.contains(0) else {
                throw .invalidXattrName
            }
            guard Self.isAllowedXattrName(name), !(decmpfs && name == Self.resourceForkName) else {
                throw .xattrNotAllowed(name)
            }
            guard names.insert(name).inserted else { throw .duplicateXattrName(name) }
        }
    }

    /// Whether the format carries an extended attribute named `name`.
    static func isAllowedXattrName(_ name: Data) -> Bool {
        allowedXattrNames.contains(name)
            || (name.count > allowedXattrPrefix.count && name.starts(with: allowedXattrPrefix))
    }

    /// Whether `name` is one path component a POSIX file system takes as it is.
    static func isValidName(_ name: Data) -> Bool {
        guard !name.isEmpty, name.count <= maxNameByteCount else { return false }
        guard name != Data([0x2E]), name != Data([0x2E, 0x2E]) else { return false }
        return !name.contains(0x2F) && !name.contains(0)
    }
}
