#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaContainer
import KernovaWire
import SwiftProtobuf
import Testing

/// A protobuf varint.
private func varint(_ value: Int) -> Data {
    var bytes = Data()
    var remaining = value
    repeat {
        let low = UInt8(remaining & 0x7F)
        remaining >>= 7
        bytes.append(remaining == 0 ? low : low | 0x80)
    } while remaining != 0
    return bytes
}

/// Field `number` as a length-delimited field holding `bytes`.
private func field(_ number: Int, _ bytes: Data) -> Data {
    varint(number << 3 | 2) + varint(bytes.count) + bytes
}

/// Field 99, a varint the schema does not define.
private let unknownField = varint(99 << 3) + varint(1)

private func xattr(_ attributeName: Data, _ value: Data = Data([1])) -> Kernova_V2_Xattr {
    var xattr = Kernova_V2_Xattr()
    xattr.name = attributeName
    xattr.value = value
    return xattr
}

private func fileWith(_ edit: (inout EntryHeader) -> Void) -> Data {
    var header = plainFile("f", depth: 0, size: 0)
    edit(&header)
    return ContainerLimitTests.single(header)
}

private func fileError(_ edit: (inout EntryHeader) -> Void) -> ContainerError? {
    decodingError(fileWith(edit), accepting: generous(.file))
}

@Suite("DATA entries are only ever the sole root")
struct DataPlacementTests {
    @Test("A nameless DATA entry inside a directory is refused by the decoder")
    func nestedDataRefused() {
        var nested = inlineData(size: 3)
        nested.depth = 1
        let container =
            headerRecord(directory("d", depth: 0)) + headerRecord(nested) + record(.chunk, Data("abc".utf8))
            + endRecord(entries: 2, bytes: 3)
        #expect(decodingError(container, accepting: generous(.folder)) == .dataEntryNotRoot)
    }

    @Test("The encoder refuses a nameless DATA entry inside a directory")
    func encoderRefusesNestedData() throws {
        var nested = inlineData(size: 0)
        nested.depth = 1
        var encoder = ContainerEncoder(accepting: generous(.folder), policy: .never)
        _ = try encoder.entry(directory("d", depth: 0))
        #expect(throws: ContainerError.dataEntryNotRoot) { try encoder.entry(nested) }
    }

    @Test("A DATA root decodes for an INLINE pull")
    func dataRoot() {
        let container = ContainerLimitTests.single(inlineData(size: 2), bytes: Data([1, 2]))
        #expect(decodingError(container, accepting: generous(.inline)) == nil)
    }
}

@Suite("The root entry's type matches the pulled representation's storage")
struct RootTypeTests {
    static let roots: [(EntryHeader, Representation.Storage)] = [
        (inlineData(size: 0), .inline), (plainFile("f", depth: 0, size: 0), .file),
        (directory("d", depth: 0), .folder),
    ]

    @Test(
        "Only the matching root decodes, for each storage", arguments: [Representation.Storage.inline, .file, .folder])
    func matrix(storage: Representation.Storage) {
        for (header, sends) in Self.roots {
            let error = decodingError(ContainerLimitTests.single(header), accepting: generous(storage))
            if sends == storage {
                #expect(error == nil, "\(header.type) for \(storage)")
            } else {
                #expect(error == .rootTypeMismatch(header.type, expected: storage), "\(header.type) for \(storage)")
            }
        }
    }

    @Test("A symlink is never a root", arguments: [Representation.Storage.inline, .file, .folder, .unspecified])
    func rootSymlink(storage: Representation.Storage) {
        let container = ContainerLimitTests.single(symlink("s", depth: 0, target: "/etc"))
        #expect(
            decodingError(container, accepting: generous(storage)) == .rootTypeMismatch(.symlink, expected: storage))
    }

    @Test("A FILE root on a FOLDER pull is refused by the encoder too")
    func encoderRefusesWrongRoot() {
        var encoder = ContainerEncoder(accepting: generous(.folder), policy: .never)
        #expect(throws: ContainerError.rootTypeMismatch(.file, expected: .folder)) {
            try encoder.entry(plainFile("f", depth: 0, size: 0))
        }
    }

    @Test("An unspecified storage admits no root")
    func unspecifiedStorage() {
        let container = ContainerLimitTests.single(plainFile("f", depth: 0, size: 0))
        #expect(
            decodingError(container, accepting: generous(.unspecified))
                == .rootTypeMismatch(.file, expected: .unspecified))
    }
}

@Suite("Extended attributes")
struct XattrRuleTests {
    @Test(
        "The allowlist: Finder tags and user attributes decode",
        arguments: ["com.apple.metadata:_kMDItemUserTags", "user.a", "user.xdg.tags"])
    func allowed(attributeName: String) {
        #expect(fileError { $0.xattrs = [xattr(name(attributeName))] } == nil)
    }

    @Test(
        "Names off the allowlist are refused",
        arguments: [
            "com.apple.decmpfs", "com.apple.quarantine", "com.apple.metadata:kMDItemWhereFroms", "user.", "user",
            "security.selinux", "trusted.x", "com.apple.ResourceFork", "com.apple.ResourceFork.x",
        ])
    func refused(attributeName: String) {
        #expect(fileError { $0.xattrs = [xattr(name(attributeName))] } == .xattrNotAllowed(name(attributeName)))
    }

    @Test("A name holding NUL is refused before the allowlist, so com.apple.decmpfs\\0 cannot pass as another")
    func nulInName() {
        let decmpfs = Data("com.apple.decmpfs".utf8) + Data([0])
        let value = decmpfsAttribute(type: 1, size: 5, tail: Data("hello".utf8))
        #expect(fileError { $0.xattrs = [xattr(decmpfs, value)] } == .invalidXattrName)
        let user = Data("user.a".utf8) + Data([0]) + Data("b".utf8)
        #expect(fileError { $0.xattrs = [xattr(user)] } == .invalidXattrName)
    }

    @Test("A name of 255 bytes decodes; empty and 256 bytes are refused")
    func nameLength() {
        let edge = Data("user.".utf8) + Data(repeating: 0x61, count: 250)
        #expect(edge.count == 255)
        #expect(fileError { $0.xattrs = [xattr(edge)] } == nil)
        #expect(fileError { $0.xattrs = [xattr(edge + Data([0x61]))] } == .invalidXattrName)
        #expect(fileError { $0.xattrs = [xattr(Data())] } == .invalidXattrName)
    }

    @Test("Two attributes of one name are refused")
    func duplicates() {
        let duplicate = name("user.a")
        let error = fileError { $0.xattrs = [xattr(duplicate, Data([1])), xattr(duplicate, Data([2]))] }
        #expect(error == .duplicateXattrName(duplicate))
        #expect(fileError { $0.xattrs = [xattr(name("user.a")), xattr(name("user.b"))] } == nil)
    }

    @Test("A resource fork travels as chunks, never as an attribute, beside any storage")
    func resourceForkNeverAnAttribute() {
        var compressed = decmpfsFile(
            "c", depth: 0, attribute: decmpfsAttribute(type: 4, size: 1), resourceForkSize: 0)
        compressed.xattrs = [xattr(name("com.apple.ResourceFork"))]
        var plain = plainFile("p", depth: 0, size: 0)
        plain.xattrs = [xattr(name("com.apple.ResourceFork"))]
        for header in [compressed, plain] {
            #expect(
                decodingError(ContainerLimitTests.single(header), accepting: generous(.file))
                    == .xattrNotAllowed(name("com.apple.ResourceFork")))
        }
    }

    @Test("The encoder refuses an attribute off the allowlist")
    func encoderRefuses() {
        var header = plainFile("f", depth: 0, size: 0)
        header.xattrs = [xattr(name("com.apple.quarantine"))]
        var encoder = ContainerEncoder(accepting: generous(.file), policy: .never)
        #expect(throws: ContainerError.xattrNotAllowed(name("com.apple.quarantine"))) { try encoder.entry(header) }
    }
}

@Suite("Resource forks")
struct ResourceForkRuleTests {
    @Test("A file's resource fork follows its data as chunks, with an event between them")
    func forkFollowsData() {
        let header = withResourceFork(plainFile("f", depth: 0, size: 3), size: 2)
        let decoded = decode(
            headerRecord(header) + record(.chunk, Data("abc".utf8)) + record(.chunk, Data("de".utf8))
                + endRecord(entries: 1, bytes: 5))
        #expect(decoded.error == nil)
        #expect(
            decoded.events == [
                .beginFile(header), .bytes(Data("abc".utf8)), .resourceFork, .bytes(Data("de".utf8)), .finishFile,
                .end,
            ])
    }

    @Test("A chunk never spans the data and the fork")
    func chunkStopsAtData() {
        let header = withResourceFork(plainFile("f", depth: 0, size: 3), size: 2)
        let container =
            headerRecord(header) + record(.chunk, Data("abcde".utf8)) + endRecord(entries: 1, bytes: 5)
        #expect(decodingError(container) == .chunkPastEntrySize(count: 5, remaining: 3))
        var encoder = ContainerEncoder(accepting: generous(), policy: .never)
        _ = try? encoder.entry(header)
        #expect(throws: ContainerError.chunkPastEntrySize(count: 5, remaining: 3)) {
            try encoder.bytes(Data("abcde".utf8))
        }
    }

    @Test("A file with only a fork starts it at once, and zero runs and LZ4 chunks carry it as they carry data")
    func forkOnlyFile() throws {
        var fork = Data(String(repeating: "icon ", count: 2_000).utf8)
        fork.append(Data(count: 300_000))
        let header = withResourceFork(lz4File("Icon\r", depth: 0, size: 0), size: UInt64(fork.count))
        var encoder = ContainerEncoder(
            accepting: generous(), policy: ChunkCompressionPolicy(attemptsLZ4: true, abandonAfterUnshrunkChunks: nil))
        var container = try encoder.entry(header)
        container += try encoder.encode(.resourceFork)
        container += try encoder.bytes(fork)
        container += try encoder.end()
        #expect(recordOffsets(container).map(\.kind) == [.header, .lz4Chunk, .zeroRun, .end])
        let decoded = decode(container)
        #expect(decoded.error == nil)
        #expect(Array(decoded.events.prefix(2)) == [.beginFile(header), .resourceFork])
        #expect(content(of: decoded.events) == fork)
    }

    @Test(
        "A resource fork on DATA, a directory or a symlink is refused",
        arguments: [EntryHeader.TypeEnum.data, .directory, .symlink])
    func forkOnlyOnFiles(type: EntryHeader.TypeEnum) {
        // A symlink is never a representation's own entry, so it lies in a folder.
        let (root, header): (EntryHeader?, EntryHeader) =
            switch type {
            case .data: (nil, inlineData(size: 0))
            case .directory: (nil, directory("d", depth: 0))
            default: (directory("d", depth: 0), symlink("l", depth: 1, target: "t"))
            }
        let forked = withResourceFork(header, size: 1)
        let container = (root.map(headerRecord) ?? Data()) + headerRecord(forked) + endRecord(entries: 2, bytes: 1)
        #expect(decodingError(container) == .resourceForkNotAllowed(type))
        var encoder = ContainerEncoder(accepting: generous(storage(sending: root?.type ?? type)), policy: .never)
        if let root { _ = try? encoder.entry(root) }
        #expect(throws: ContainerError.resourceForkNotAllowed(type)) { try encoder.entry(forked) }
    }

    @Test("A resource fork of 4 GiB decodes its header; one byte more is refused")
    func forkSizeLimit() {
        let edge = ValidatedEntry.maxResourceForkByteCount
        #expect(throws: Never.self) {
            try ValidatedEntry(withResourceFork(plainFile("f", depth: 0, size: 0), size: edge))
        }
        #expect(
            decodingError(
                ContainerLimitTests.single(withResourceFork(plainFile("f", depth: 0, size: 0), size: edge + 1)))
                == .resourceForkTooLarge(edge + 1))
    }

    @Test("Starting a fork the header does not declare, or before the data is whole, is refused by the encoder")
    func encoderForkMarker() throws {
        var encoder = ContainerEncoder(accepting: generous(), policy: .never)
        _ = try encoder.entry(withResourceFork(plainFile("f", depth: 0, size: 3), size: 2))
        #expect(throws: ContainerError.entryIncomplete(remaining: 3)) { try encoder.encode(.resourceFork) }
        _ = try encoder.bytes(Data("abc".utf8))
        #expect(try encoder.encode(.resourceFork).isEmpty)
        #expect(throws: ContainerError.entryIncomplete(remaining: 2)) { try encoder.encode(.finishFile) }
        _ = try encoder.bytes(Data("de".utf8))
        #expect(throws: ContainerError.eventOutOfOrder) { try encoder.encode(.resourceFork) }
        var unforked = ContainerEncoder(accepting: generous(), policy: .never)
        _ = try unforked.entry(plainFile("f", depth: 0, size: 1))
        _ = try unforked.bytes(Data("a".utf8))
        #expect(throws: ContainerError.resourceForkUndeclared) { try unforked.encode(.resourceFork) }
    }

    @Test("A plain file's data and fork together count against the ceiling")
    func forkCountsAgainstCeiling() {
        let acceptance = ContainerAcceptance(storage: .file, byteCeiling: 10, decmpfsTypes: [], acceptsLZ4: false)
        let fits = withResourceFork(plainFile("f", depth: 0, size: 6), size: 4)
        let over = withResourceFork(plainFile("f", depth: 0, size: 6), size: 5)
        let body = Data(repeating: 1, count: 6)
        #expect(
            decodingError(
                headerRecord(fits) + record(.chunk, body) + record(.chunk, Data(repeating: 2, count: 4))
                    + endRecord(entries: 1, bytes: 10), accepting: acceptance) == nil)
        #expect(
            decodingError(headerRecord(over) + record(.chunk, body), accepting: acceptance)
                == .exceedsByteCeiling(declared: 11, ceiling: 10))
    }
}

@Suite("The byte ceiling bounds landed bytes")
struct LandedCeilingTests {
    static func decmpfs(logical: UInt64, fork: UInt64, ceiling: UInt64) -> ContainerError? {
        let acceptance = ContainerAcceptance(storage: .file, byteCeiling: ceiling, decmpfsTypes: [4], acceptsLZ4: false)
        let header = decmpfsFile(
            "c", depth: 0, attribute: decmpfsAttribute(type: 4, size: logical), resourceForkSize: fork)
        var container = headerRecord(header)
        if fork > 0 { container += record(.chunk, Data(repeating: 1, count: Int(fork))) }
        return decodingError(container + endRecord(entries: 1, bytes: fork), accepting: acceptance)
    }

    @Test("A decmpfs file declaring 2^62 logical bytes is refused under a 100-byte ceiling")
    func hugeLogicalSize() {
        #expect(
            Self.decmpfs(logical: 1 << 62, fork: 10, ceiling: 100)
                == .exceedsByteCeiling(declared: 1 << 62, ceiling: 100))
    }

    @Test("A decmpfs file's logical size at the ceiling decodes; one byte more is refused")
    func logicalSizeEdge() {
        #expect(Self.decmpfs(logical: 100, fork: 10, ceiling: 100) == nil)
        #expect(Self.decmpfs(logical: 101, fork: 10, ceiling: 100) == .exceedsByteCeiling(declared: 101, ceiling: 100))
    }

    @Test("A resource fork larger than the logical size counts in its place")
    func forkCounts() {
        #expect(Self.decmpfs(logical: 1, fork: 100, ceiling: 100) == nil)
        #expect(Self.decmpfs(logical: 1, fork: 101, ceiling: 100) == .exceedsByteCeiling(declared: 101, ceiling: 100))
    }
}

@Suite("Header fields within their ranges")
struct HeaderRangeTests {
    @Test("A symlink target of 1,023 bytes decodes; 1,024 is refused")
    func symlinkTargetLength() {
        let edge = String(repeating: "a", count: 1_023)
        #expect(decodingError(ContainerLimitTests.inFolder(symlink("s", depth: 1, target: edge))) == nil)
        #expect(
            decodingError(ContainerLimitTests.inFolder(symlink("s", depth: 1, target: edge + "a")))
                == .invalidSymlinkTarget)
        let long = String(repeating: "a/", count: 30_000)
        #expect(
            decodingError(ContainerLimitTests.inFolder(symlink("s", depth: 1, target: long))) == .invalidSymlinkTarget)
    }

    @Test("Mode 07777 decodes; 010000 and a file-type mode are refused")
    func mode() {
        #expect(fileError { $0.mode = 0o7777 } == nil)
        #expect(fileError { $0.mode = 0o10000 } == .modeOutOfRange(0o10000))
        #expect(fileError { $0.mode = 0o170_777 } == .modeOutOfRange(0o170_777))
    }

    @Test("Nanoseconds of 999,999,999 decode; 1,000,000,000 is refused, in both times")
    func nanoseconds() {
        #expect(fileError { $0.modificationTime.nanoseconds = 999_999_999 } == nil)
        #expect(fileError { $0.birthTime.nanoseconds = 999_999_999 } == nil)
        #expect(fileError { $0.modificationTime.nanoseconds = 1_000_000_000 } == .nanosecondsOutOfRange(1_000_000_000))
        #expect(fileError { $0.birthTime.nanoseconds = 1_000_000_000 } == .nanosecondsOutOfRange(1_000_000_000))
        #expect(fileError { $0.modificationTime.nanoseconds = 4_000_000_000 } == .nanosecondsOutOfRange(4_000_000_000))
    }

    @Test("The carried Darwin flags decode, alone and together", arguments: [UInt32(0x1), 0x8, 0x8000, 0x8009])
    func allowedFlags(flags: UInt32) {
        #expect(fileError { $0.darwinFlags = flags } == nil)
    }

    @Test(
        "Every other Darwin flag is refused, never masked",
        arguments: [
            UInt32(0x2),  // UF_IMMUTABLE
            0x4,  // UF_APPEND
            0x20,  // UF_COMPRESSED
            0x40,  // UF_TRACKED
            0x80,  // UF_DATAVAULT
            0x100,  // an undefined owner bit
            0x0001_0000,  // SF_ARCHIVED
            0x0002_0000,  // SF_IMMUTABLE
            0x0008_0000,  // SF_RESTRICTED
            0x4000_0000,  // SF_DATALESS
            0x8000_0000,  // a synthetic bit
        ])
    func refusedFlags(flag: UInt32) {
        #expect(fileError { $0.darwinFlags = flag } == .darwinFlagsNotAllowed(flag))
        #expect(fileError { $0.darwinFlags = flag | 0x8009 } == .darwinFlagsNotAllowed(flag))
    }

    @Test("UF_COMPRESSED with a system flag and the high bit, as a reviewer sent it, is refused")
    func reviewerFlags() {
        let flags: UInt32 = 0x20 | 0x0002_0000 | 0x8000_0000
        #expect(fileError { $0.darwinFlags = flags } == .darwinFlagsNotAllowed(flags))
    }
}

@Suite("Unknown protobuf fields make a record malformed")
struct UnknownFieldTests {
    static let file = serialized(plainFile("f", depth: 0, size: 0))
    static let end = endRecord(entries: 1, bytes: 0)

    @Test("An unknown field in a header is refused")
    func inHeader() {
        let payload = Self.file + field(99, Data(repeating: 0x41, count: 1_000))
        #expect(decodingError(record(.header, payload) + Self.end, accepting: generous(.file)) == .unknownFields)
    }

    @Test("An unknown field in the end record is refused")
    func inEnd() {
        let end =
            serialized(
                {
                    var end = EndRecord(); end.entries = 1; return end
                }()) + unknownField
        #expect(
            decodingError(record(.header, Self.file) + record(.end, end), accepting: generous(.file)) == .unknownFields)
    }

    @Test("An unknown field in a message nested in a header is refused", arguments: [6, 7, 8, 10, 11, 12])
    func nested(fieldNumber: Int) {
        var header = plainFile("f", depth: 0, size: 0)
        // Fields 10 to 12 are the storage itself.
        if fieldNumber >= 10 { header.storage = nil }
        let known: Data
        switch fieldNumber {
        case 8: known = field(1, Data("user.a".utf8))
        case 12: known = field(1, decmpfsAttribute(type: 3, size: 1, tail: Data([0x78])))
        default: known = Data()
        }
        let acceptance = generous(.file)
        let clean = serialized(header) + field(fieldNumber, known)
        #expect(decodingError(record(.header, clean) + Self.end, accepting: acceptance) == nil)
        let carrying = serialized(header) + field(fieldNumber, known + unknownField)
        #expect(decodingError(record(.header, carrying) + Self.end, accepting: acceptance) == .unknownFields)
    }

    @Test("Deeply nested unknown groups in a header are refused without a crash")
    func nestedGroups() {
        let depth = 30_000
        let payload = Data(repeating: 0x7B, count: depth) + Data(repeating: 0x7C, count: depth)
        #expect(decodingError(record(.header, payload) + Self.end, accepting: generous(.file)) != nil)
    }
}

@Suite("Committing after finish")
struct FinishContractTests {
    @Test("Bytes after the end record in the same feed: .end comes first, then the error, and finish throws")
    func endThenTrailing() {
        var decoder = ContainerDecoder(accepting: generous(.file))
        decoder.feed(headerRecord(plainFile("f", depth: 0, size: 0)) + endRecord(entries: 1, bytes: 0) + Data([1]))
        var events: [TreeEvent] = []
        var thrown: ContainerError?
        do {
            while let event = try decoder.next() { events.append(event) }
        } catch {
            thrown = error
        }
        #expect(events.last == .end)
        #expect(thrown == .bytesAfterEnd)
        #expect(throws: ContainerError.bytesAfterEnd) { try decoder.finish() }
    }
}
