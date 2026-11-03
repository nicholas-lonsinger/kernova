#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import KernovaContainer
import KernovaFileTree
import KernovaPortableTestSupport
import KernovaWire
import SwiftProtobuf
import Testing

@testable import KernovaTreeTransfer

// MARK: - Entries

func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

func directory(_ name: [UInt8], depth: UInt32, mode: UInt32 = 0o755) -> EntryHeader {
    var header = EntryHeader()
    header.depth = depth
    header.name = Data(name)
    header.type = .directory
    header.mode = mode
    return header
}

func directory(_ name: String, depth: UInt32, mode: UInt32 = 0o755) -> EntryHeader {
    directory(bytes(name), depth: depth, mode: mode)
}

func file(_ name: [UInt8], depth: UInt32, size: UInt64, mode: UInt32 = 0o644) -> EntryHeader {
    var header = EntryHeader()
    header.depth = depth
    header.name = Data(name)
    header.type = .file
    header.mode = mode
    header.plain.size = size
    return header
}

func file(_ name: String, depth: UInt32, size: UInt64, mode: UInt32 = 0o644) -> EntryHeader {
    file(bytes(name), depth: depth, size: size, mode: mode)
}

func symlinkEntry(_ name: String, depth: UInt32, target: String) -> EntryHeader {
    var header = EntryHeader()
    header.depth = depth
    header.name = Data(name.utf8)
    header.type = .symlink
    header.mode = 0o755
    header.symlinkTarget = Data(target.utf8)
    return header
}

/// A file larger than a folder batch takes, so it is written as it arrives.
let largeFileSize = FolderBatch.largestFile + 1

// MARK: - Containers

/// A container's records written one by one, framing and checksums right, grammar unchecked — so it can
/// hold what no encoder writes — with the end record's counts kept as the records are added.
struct RawContainer {
    private(set) var data = Data()
    /// Where each record starts, and the end of the last.
    private(set) var boundaries: [Int] = [0]
    private var entries: UInt64 = 0
    private var carried: UInt64 = 0

    mutating func record(_ kind: ContainerRecordKind, _ payload: Data) {
        ContainerRecord.append(kind, payload: payload, to: &data)
        boundaries.append(data.count)
    }

    mutating func header(_ header: EntryHeader) {
        entries += 1
        record(.header, Self.serialized(header))
    }

    mutating func chunk(_ bytes: Data) {
        carried += UInt64(bytes.count)
        record(.chunk, bytes)
    }

    mutating func zeros(_ count: UInt64) {
        carried += count
        record(.zeroRun, Data((0..<8).map { UInt8(truncatingIfNeeded: count >> ($0 * 8)) }))
    }

    /// A file entry and its bytes, in chunks of at most 1 MiB.
    mutating func file(_ header: EntryHeader, _ content: Data) {
        self.header(header)
        var start = content.startIndex
        while start < content.endIndex {
            let end = min(start + ContainerRecord.maxChunkPayload, content.endIndex)
            chunk(content[start..<end])
            start = end
        }
    }

    mutating func end() {
        var end = EndRecord()
        end.entries = entries
        end.bytes = carried
        record(.end, Self.serialized(end))
    }

    static func serialized(_ message: some SwiftProtobuf.Message) -> Data {
        do {
            return try message.serializedBytes()
        } catch {
            preconditionFailure("a proto3 message always serializes: \(error)")
        }
    }
}

/// A pull of a FOLDER (or, with `.file`, a FILE) representation, up to `ceiling` bytes.
func acceptance(_ storage: Representation.Storage = .folder, ceiling: UInt64 = 1 << 30) -> ContainerAcceptance {
    ContainerAcceptance(storage: storage, byteCeiling: ceiling, decmpfsTypes: [], acceptsLZ4: true)
}

/// A pattern of `count` bytes that is never all zero.
func pattern(_ count: Int, seed: UInt8 = 1) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) | 1 })
}

// MARK: - The destination

/// A scratch directory holding `destination`, where items land, and `outside`, holding one file nothing
/// should ever touch — the tree every case checks is unchanged but for what landed.
final class Landing {
    let scratch: PortableScratchDirectory
    let fileSystem: POSIXTreeFileSystem

    var destinationPath: String { scratch.path + "/destination" }
    var outsidePath: String { scratch.path + "/outside" }

    init(kernelContainment: Bool) throws {
        scratch = try PortableScratchDirectory(prefix: "tree-writer")
        fileSystem = POSIXTreeFileSystem(kernelContainment: kernelContainment)
        try #require(mkdir(destinationPath, 0o755) == 0)
        try #require(mkdir(outsidePath, 0o755) == 0)
        let sentinel = open(outsidePath + "/sentinel", O_WRONLY | O_CREAT | O_EXCL, 0o644)
        try #require(sentinel >= 0)
        close(sentinel)
    }

    deinit {
        // A landed tree may hold directories its owner cannot write, which the scratch directory's own
        // removal cannot empty.
        if let top = try? fileSystem.openDirectory(bytes(scratch.path), in: AT_FDCWD) {
            for name in (try? fileSystem.names(in: top)) ?? [] {
                try? TreeRemoval.remove(name, in: top, on: fileSystem)
            }
            fileSystem.close(top)
        }
    }

    func openDestination() throws -> Int32 {
        try fileSystem.openDirectory(bytes(destinationPath), in: AT_FDCWD)
    }

    /// A receiver landing what `acceptance` admits in the destination.
    func receiver(_ acceptance: ContainerAcceptance) throws -> TreeReceiver<POSIXTreeFileSystem> {
        TreeReceiver(
            accepting: acceptance, fileSystem: fileSystem, destination: try openDestination(),
            destinationPathByteCount: destinationPath.utf8.count)
    }

    /// A writer landing in the destination, driven by events directly.
    func writer(ceiling: UInt64 = 1 << 30) throws -> TreeWriter<POSIXTreeFileSystem> {
        TreeWriter(
            fileSystem: fileSystem, destination: try openDestination(),
            destinationPathByteCount: destinationPath.utf8.count, byteCeiling: ceiling)
    }

    /// Feeds `container` in pieces of `pieceSize` bytes, then finishes, returning the landed name or the
    /// failure.
    func land(
        _ container: Data, accepting acceptance: ContainerAcceptance = acceptance(), pieceSize: Int? = nil
    ) throws -> Result<[UInt8], TreeWriteFailure> {
        let receiver = try receiver(acceptance)
        return Result { () throws(TreeWriteFailure) in
            let step = max(1, pieceSize ?? container.count)
            var start = container.startIndex
            while start < container.endIndex {
                let end = min(start + step, container.endIndex)
                try receiver.receive(container[start..<end])
                start = end
            }
            return try receiver.finish()
        }
    }

    /// Every entry under the scratch directory but the destination's landed item `landed`, as `path: kind`.
    func entriesOutside(landed: [UInt8]? = nil) throws -> [String] {
        var found: [String] = []
        try walk(bytes(scratch.path), in: AT_FDCWD, path: "") { path, name in
            path == "/destination" && name == landed
        } visit: {
            found.append($0)
        }
        return found.sorted()
    }

    /// The entries of the landed item `name`, as `path: kind`, relative to it.
    func landedEntries(_ name: [UInt8]) throws -> [String] {
        var found: [String] = []
        let top = try openDestination()
        defer { fileSystem.close(top) }
        let status = try fileSystem.status(of: name, in: top)
        found.append(".: \(Self.describe(status))")
        if status.kind == .directory {
            try walk(name, in: top, path: ".") { _, _ in
                false
            } visit: {
                found.append($0)
            }
        }
        return found.sorted()
    }

    /// What every case asserts: the scratch directory holds the destination, empty but for `landed`, and
    /// the untouched outside directory.
    func expectNothingOutside(landed: [UInt8]? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(
            try entriesOutside(landed: landed)
                == [
                    "/destination: directory", "/outside: directory", "/outside/sentinel: regular 0",
                ].sorted(), sourceLocation: sourceLocation)
    }

    private func walk(
        _ name: [UInt8], in directory: Int32, path: String, skip: (String, [UInt8]) -> Bool,
        visit: (String) -> Void
    ) throws {
        let descriptor = try fileSystem.openDirectory(name, in: directory)
        defer { fileSystem.close(descriptor) }
        for child in try fileSystem.names(in: descriptor) where !skip(path, child) {
            let childPath = path + "/" + Self.display(child)
            let status = try fileSystem.status(of: child, in: descriptor)
            var line = "\(childPath): \(Self.describe(status))"
            if status.kind == .symbolicLink {
                line += " -> " + Self.display(try fileSystem.linkTarget(of: child, in: descriptor))
            }
            visit(line)
            if status.kind == .directory {
                // A landed directory may withhold its owner's search bit.
                if status.permissions & 0o500 != 0o500 {
                    try fileSystem.setMode(status.permissions | 0o700, of: child, in: descriptor)
                    defer { try? fileSystem.setMode(status.permissions, of: child, in: descriptor) }
                    try walk(child, in: descriptor, path: childPath, skip: skip, visit: visit)
                } else {
                    try walk(child, in: descriptor, path: childPath, skip: skip, visit: visit)
                }
            }
        }
    }

    static func describe(_ status: FileStatus) -> String {
        switch status.kind {
        case .regular: "regular \(status.size)"
        case .directory: "directory"
        case .symbolicLink: "symlink"
        default: "\(status.kind)"
        }
    }

    static func display(_ name: [UInt8]) -> String {
        name.map { $0 >= 0x21 && $0 < 0x7F ? String(UnicodeScalar($0)) : "%" + String($0, radix: 16) }.joined()
    }
}

/// The failure a result came to, or nil when it landed.
extension Result where Failure == TreeWriteFailure {
    var failure: TreeWriteFailure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

/// The `errno` a `.system` or `.refused` failure carries.
extension TreeWriteFailure {
    var code: Int32? {
        switch reason {
        case .system(let error), .refused(let error): error.code
        default: nil
        }
    }
}

let bothLayers = [false, true]
#endif
