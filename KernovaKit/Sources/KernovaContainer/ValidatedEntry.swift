#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// An entry header that keeps every rule the format holds one entry to, whatever produced it: its name, its
/// mode, flags and times, its symlink target, its extended attributes, and its storage and resource fork
/// against its type. `TreeEventSequence` admits no entry without one, so every producer of `TreeEvent`s is
/// held to the same rules.
///
/// The rules that depend on a pull — the codecs, decmpfs types and byte ceiling it accepts — and an entry's
/// place in the tree are the sequence's.
public struct ValidatedEntry: Sendable {
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
    public static let allowedDarwinFlags: UInt32 = 0x0000_8009

    /// The extended attributes the format carries, by exact name: Finder tags. A resource fork travels as an
    /// entry's own chunks, never as an attribute.
    static let allowedXattrNames: Set<Data> = [Data("com.apple.metadata:_kMDItemUserTags".utf8)]

    /// The largest resource fork, 4 GiB: Darwin, the one OS that keeps resource forks, reads and writes one
    /// in pieces at a 32-bit position (`getxattr(2)`, `setxattr(2)`).
    public static let maxResourceForkByteCount: UInt64 = 1 << 32

    /// The extended attribute namespace the format carries whole: Linux's `user.*`.
    static let allowedXattrPrefix = Data("user.".utf8)

    /// The header, which keeps every rule.
    public let header: EntryHeader

    /// The bytes the entry's data chunks carry: its size for plain or LZ4 storage, none for decmpfs storage or
    /// an entry that is not a file.
    public let dataByteCount: UInt64

    /// The bytes its resource fork's chunks carry, which follow the data's; 0 for none.
    public let resourceForkByteCount: UInt64

    /// The header of its `com.apple.decmpfs` attribute, for decmpfs storage.
    public let decmpfs: DecmpfsHeader?

    /// Whether its chunks may be LZ4 blocks.
    public let isLZ4: Bool

    /// The logical bytes it lands, which a pull's byte ceiling bounds: its data and its resource fork, and for
    /// decmpfs storage, whose data is the resource fork read through the attribute, the larger of the
    /// attribute's uncompressed size and the fork, so neither can pass the ceiling.
    public var landedByteCount: UInt64 {
        if let decmpfs { return max(decmpfs.uncompressedSize, resourceForkByteCount) }
        return carriedByteCount
    }

    /// The bytes all its chunks carry, data then resource fork.
    public var carriedByteCount: UInt64 {
        let (sum, overflow) = dataByteCount.addingReportingOverflow(resourceForkByteCount)
        return overflow ? .max : sum
    }

    /// `header`, once it keeps every rule.
    ///
    /// - Parameter header: The entry's header.
    /// - Throws: `ContainerError` naming the first rule it breaks.
    public init(_ header: EntryHeader) throws(ContainerError) {
        try Self.check(header)
        (dataByteCount, decmpfs, isLZ4) = try Self.storage(of: header)
        guard header.resourceForkSize == 0 || header.type == .file else {
            throw .resourceForkNotAllowed(header.type)
        }
        guard dataByteCount <= UInt64(Int64.max) else { throw .fileTooLarge(dataByteCount) }
        guard header.resourceForkSize <= Self.maxResourceForkByteCount else {
            throw .resourceForkTooLarge(header.resourceForkSize)
        }
        resourceForkByteCount = header.resourceForkSize
        if let decmpfs {
            try Self.checkPayload(of: decmpfs, attribute: header.decmpfs.attribute, fork: resourceForkByteCount)
        }
        self.header = header
    }

    /// Checks that decmpfs storage carries compressed bytes where its type keeps them: past the attribute's
    /// header, or in a resource fork. Without them the kernel takes the file compressed and reads it as nothing,
    /// or fails its `open` (docs/research/2026-10-24-decmpfs-pass-through.md, finding 9).
    private static func checkPayload(of decmpfs: DecmpfsHeader, attribute: Data, fork: UInt64)
        throws(ContainerError)
    {
        switch DecmpfsHeader.payload(of: decmpfs.compressionType) {
        case .attribute:
            guard attribute.count > DecmpfsHeader.byteCount else {
                throw .decmpfsPayloadMissing(decmpfs.compressionType)
            }
        case .resourceFork:
            guard fork > 0 else { throw .decmpfsPayloadMissing(decmpfs.compressionType) }
        case nil:
            throw .decmpfsTypeUnknown(decmpfs.compressionType)
        }
    }

    private static func check(_ header: EntryHeader) throws(ContainerError) {
        guard header.unknownFields.data.isEmpty else { throw .unknownFields }
        if header.type == .data {
            let bare =
                header.depth == 0 && header.name.isEmpty && header.mode == 0 && header.darwinFlags == 0
                && !header.hasModificationTime && !header.hasBirthTime && header.xattrs.isEmpty
                && header.symlinkTarget.isEmpty
            guard bare else { throw .dataEntryNotBare }
            return
        }
        guard isValidName(header.name) else { throw .invalidName }
        guard header.mode <= maxMode else { throw .modeOutOfRange(header.mode) }
        guard header.darwinFlags & ~allowedDarwinFlags == 0 else {
            throw .darwinFlagsNotAllowed(header.darwinFlags & ~allowedDarwinFlags)
        }
        for time in [header.modificationTime, header.birthTime] {
            guard time.unknownFields.data.isEmpty else { throw .unknownFields }
            guard time.nanoseconds <= maxNanoseconds else { throw .nanosecondsOutOfRange(time.nanoseconds) }
        }
        if header.type == .symlink {
            let target = header.symlinkTarget
            guard !target.isEmpty, target.count <= maxSymlinkTargetByteCount, !target.contains(0) else {
                throw .invalidSymlinkTarget
            }
        } else {
            guard header.symlinkTarget.isEmpty else { throw .invalidSymlinkTarget }
        }
        try checkXattrs(of: header)
    }

    /// The bytes `header`'s data chunks carry, its decmpfs header, and whether its chunks may be LZ4, once its
    /// storage is one its type takes: plain or LZ4 for DATA and FILE, decmpfs for FILE alone, none otherwise.
    private static func storage(of header: EntryHeader) throws(ContainerError) -> (UInt64, DecmpfsHeader?, Bool) {
        switch (header.type, header.storage) {
        case (.data, .plain(let plain)?), (.file, .plain(let plain)?):
            guard plain.unknownFields.data.isEmpty else { throw .unknownFields }
            return (plain.size, nil, false)
        case (.data, .lz4(let lz4)?), (.file, .lz4(let lz4)?):
            guard lz4.unknownFields.data.isEmpty else { throw .unknownFields }
            return (lz4.size, nil, true)
        case (.file, .decmpfs(let decmpfs)?):
            guard decmpfs.unknownFields.data.isEmpty else { throw .unknownFields }
            do {
                return (0, try DecmpfsHeader(attribute: decmpfs.attribute), false)
            } catch {
                throw .malformedDecmpfsAttribute(error)
            }
        case (.directory, nil), (.symlink, nil):
            return (0, nil, false)
        default:
            throw .storageNotAllowed(header.type)
        }
    }

    private static func checkXattrs(of header: EntryHeader) throws(ContainerError) {
        var names = Set<Data>()
        for xattr in header.xattrs {
            guard xattr.unknownFields.data.isEmpty else { throw .unknownFields }
            let name = xattr.name
            guard !name.isEmpty, name.count <= maxNameByteCount, !name.contains(0) else {
                throw .invalidXattrName
            }
            guard isAllowedXattrName(name) else { throw .xattrNotAllowed(name) }
            guard names.insert(name).inserted else { throw .duplicateXattrName(name) }
        }
    }

    /// Whether the format carries an extended attribute named `name`.
    public static func isAllowedXattrName(_ name: Data) -> Bool {
        allowedXattrNames.contains(name)
            || (name.count > allowedXattrPrefix.count && name.starts(with: allowedXattrPrefix))
    }

    /// Whether `name` is one path component a POSIX file system takes as it is.
    public static func isValidName(_ name: Data) -> Bool {
        guard !name.isEmpty, name.count <= maxNameByteCount else { return false }
        guard name != Data([0x2E]), name != Data([0x2E, 0x2E]) else { return false }
        return !name.contains(0x2F) && !name.contains(0)
    }
}
