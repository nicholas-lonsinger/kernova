#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// An entry header that keeps every rule the format holds one entry to, whatever produced it: its name, its
/// mode, flags and times, its symlink target, and its extended attributes. The container grammar admits no
/// header without one, and a tree writer lands an entry's metadata only from one, so every producer of
/// `TreeEvent`s is held to the same rules.
///
/// The rules that depend on a pull — the codecs, decmpfs types and byte ceiling it accepts — and an entry's
/// place in the tree are the grammar's.
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
    static let allowedDarwinFlags: UInt32 = 0x0000_8009

    /// The extended attributes the format carries, by exact name: Finder tags and the resource fork.
    static let allowedXattrNames: Set<Data> = [
        Data("com.apple.metadata:_kMDItemUserTags".utf8), resourceForkName,
    ]

    /// The extended attribute namespace the format carries whole: Linux's `user.*`.
    static let allowedXattrPrefix = Data("user.".utf8)

    /// The resource fork, which an entry with decmpfs storage carries as its chunks instead.
    static let resourceForkName = Data("com.apple.ResourceFork".utf8)

    /// The header, which keeps every rule.
    public let header: EntryHeader

    /// `header`, once it keeps every rule.
    ///
    /// - Parameter header: The entry's header.
    /// - Throws: `ContainerError` naming the first rule it breaks.
    public init(_ header: EntryHeader) throws(ContainerError) {
        try Self.check(header)
        self.header = header
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

    private static func checkXattrs(of header: EntryHeader) throws(ContainerError) {
        var names = Set<Data>()
        let decmpfs: Bool
        if case .decmpfs = header.storage { decmpfs = true } else { decmpfs = false }
        for xattr in header.xattrs {
            guard xattr.unknownFields.data.isEmpty else { throw .unknownFields }
            let name = xattr.name
            guard !name.isEmpty, name.count <= maxNameByteCount, !name.contains(0) else {
                throw .invalidXattrName
            }
            guard isAllowedXattrName(name), !(decmpfs && name == resourceForkName) else {
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
