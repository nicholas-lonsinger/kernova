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
    var header = plainFile(depth: 0, size: 0)
    edit(&header)
    return ContainerLimitTests.single(header)
}

private func fileError(_ edit: (inout EntryHeader) -> Void) -> ContainerError? {
    decodingError(fileWith(edit), accepting: generous(.file))
}

@Suite("Extended attributes")
struct XattrRuleTests {
    @Test(
        "Names off the allowlist are refused",
        arguments: [
            "com.apple.decmpfs", "com.apple.quarantine", "com.apple.metadata:kMDItemWhereFroms", "user.", "user",
            "security.selinux", "trusted.x", "com.apple.ResourceFork", "com.apple.ResourceFork.x",
        ])
    func refused(attributeName: String) {
        #expect(fileError { $0.xattrs = [xattr(name(attributeName))] } == .xattrNotAllowed(name(attributeName)))
    }

    @Test("A name of 255 bytes decodes; empty and 256 bytes are refused")
    func nameLength() {
        let edge = Data("user.".utf8) + Data(repeating: 0x61, count: 250)
        #expect(edge.count == 255)
        #expect(fileError { $0.xattrs = [xattr(edge)] } == nil)
        #expect(fileError { $0.xattrs = [xattr(edge + Data([0x61]))] } == .invalidXattrName)
        #expect(fileError { $0.xattrs = [xattr(Data())] } == .invalidXattrName)
    }
}

@Suite("Resource forks")
struct ResourceForkRuleTests {
    @Test(
        "A resource fork on DATA, a directory or a symlink is refused",
        arguments: [EntryHeader.TypeEnum.data, .directory, .symlink])
    func forkOnlyOnFiles(type: EntryHeader.TypeEnum) {
        // A symlink is never a representation's own entry, so it lies in a folder.
        let (root, header): (EntryHeader?, EntryHeader) =
            switch type {
            case .data: (nil, inlineData(size: 0))
            case .directory: (nil, directory(depth: 0))
            default: (directory(depth: 0), symlink("l", depth: 1, target: "t"))
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
            try ValidatedEntry(withResourceFork(plainFile(depth: 0, size: 0), size: edge))
        }
        #expect(
            decodingError(
                ContainerLimitTests.single(withResourceFork(plainFile(depth: 0, size: 0), size: edge + 1)))
                == .resourceForkTooLarge(edge + 1))
    }

    @Test("Starting a fork the header does not declare, or before the data is whole, is refused by the encoder")
    func encoderForkMarker() throws {
        var encoder = ContainerEncoder(accepting: generous(), policy: .never)
        _ = try encoder.entry(withResourceFork(plainFile(depth: 0, size: 3), size: 2))
        #expect(throws: ContainerError.entryIncomplete(remaining: 3)) { try encoder.encode(.resourceFork) }
        _ = try encoder.bytes(Data("abc".utf8))
        #expect(try encoder.encode(.resourceFork).isEmpty)
        #expect(throws: ContainerError.entryIncomplete(remaining: 2)) { try encoder.encode(.finishFile) }
        _ = try encoder.bytes(Data("de".utf8))
        #expect(throws: ContainerError.eventOutOfOrder) { try encoder.encode(.resourceFork) }
        var unforked = ContainerEncoder(accepting: generous(), policy: .never)
        _ = try unforked.entry(plainFile(depth: 0, size: 1))
        _ = try unforked.bytes(Data("a".utf8))
        #expect(throws: ContainerError.resourceForkUndeclared) { try unforked.encode(.resourceFork) }
    }
}

@Suite("The byte ceiling bounds landed bytes")
struct LandedCeilingTests {
    static func decmpfs(logical: UInt64, fork: UInt64, ceiling: UInt64) -> ContainerError? {
        let acceptance = ContainerAcceptance(storage: .file, byteCeiling: ceiling, decmpfsTypes: [4], acceptsLZ4: false)
        let header = decmpfsFile(
            depth: 0, attribute: decmpfsAttribute(type: 4, size: logical), resourceForkSize: fork)
        var container = headerRecord(header)
        if fork > 0 { container += record(.chunk, Data(repeating: 1, count: Int(fork))) }
        return decodingError(container + endRecord(entries: 1, bytes: fork), accepting: acceptance)
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

    @Test("The carried Darwin flags decode, alone and together", arguments: [UInt32(0x1), 0x8, 0x8000, 0x8009])
    func allowedFlags(flags: UInt32) {
        #expect(fileError { $0.darwinFlags = flags } == nil)
    }
}

@Suite("Unknown protobuf fields make a record malformed")
struct UnknownFieldTests {
    static let file = serialized(plainFile(depth: 0, size: 0))
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
        var header = plainFile(depth: 0, size: 0)
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
