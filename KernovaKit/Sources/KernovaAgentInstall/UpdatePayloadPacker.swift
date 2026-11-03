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
import KernovaWire

/// Packs a directory as a `PAYLOAD_FORMAT_CONTAINER_TREE` update payload in the update profile, the frozen
/// subset of the container every installed agent must go on landing (`kernova_v2.proto`, "The update
/// profile"):
///
/// - the record framing, and only the header, chunk, zero-run and end records — never an LZ4 chunk;
/// - the item's own entry, a DIRECTORY at depth 0 with no name, which the lander publishes under its own;
/// - DIRECTORY, FILE and SYMLINK entries carrying only their depth, name, type, mode, a file's plain size
///   and a symlink's target — no times, flags, extended attributes or resource forks, which a signed bundle
///   does not need and whose reading differs by OS.
///
/// The bytes depend only on the tree: names in byte order, each directory before what it holds, a symlink's
/// mode always `0o755` (its own is not read the same way on every OS), so one tree always packs to one
/// payload, whose SHA-256 is the agent's identity.
public enum UpdatePayloadPacker {
    /// Why the tree could not be packed.
    public struct Failure: Error, CustomStringConvertible, Equatable {
        /// The entry, relative to the packed directory; empty for the directory itself.
        public var path: String
        /// What failed.
        public var detail: String

        /// The entry and what failed.
        public var description: String { path.isEmpty ? detail : "\(path): \(detail)" }
    }

    /// The mode every symlink is packed with.
    static let symlinkMode: UInt32 = 0o755

    /// The acceptance the packer's encoder holds the payload to: a folder, plain chunks, any size.
    static let acceptance = ContainerAcceptance(
        storage: .folder, byteCeiling: .max, decmpfsTypes: [], acceptsLZ4: false)

    /// Packs the directory at the absolute `path`, handing `output` the payload's bytes in order.
    public static func pack(directoryAt path: String, to output: @escaping (Data) throws -> Void) throws {
        let fileSystem = POSIXTreeFileSystem()
        var packer = Packer(fileSystem: fileSystem, output: output)
        let name = Array(path.utf8)
        let status = try packer.system("") { () throws(TreeFileSystemError) in
            try fileSystem.status(of: name, in: AT_FDCWD)
        }
        guard status.kind == .directory else { throw Failure(path: "", detail: "not a directory") }
        let directory = try packer.system("") { () throws(TreeFileSystemError) in
            try fileSystem.openDirectory(name, in: AT_FDCWD)
        }
        defer { fileSystem.close(directory) }
        var root = EntryHeader()
        root.depth = 0
        root.type = .directory
        root.mode = status.permissions
        try packer.emit(root, path: "")
        try packer.walk(directory, depth: 1, path: "")
        try packer.finish()
    }

    /// The walk's state: the encoder and where its records go.
    private struct Packer {
        let fileSystem: POSIXTreeFileSystem
        let output: (Data) throws -> Void
        var encoder = ContainerEncoder(accepting: UpdatePayloadPacker.acceptance, policy: .never)

        init(fileSystem: POSIXTreeFileSystem, output: @escaping (Data) throws -> Void) {
            self.fileSystem = fileSystem
            self.output = output
        }

        /// Packs everything in `directory`, whose entries lie at `depth`, in byte order of their names.
        mutating func walk(_ directory: Int32, depth: UInt32, path: String) throws {
            let names = try system(path) { () throws(TreeFileSystemError) in try fileSystem.names(in: directory) }
            for name in names.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                let entryPath = path.isEmpty ? Self.text(name) : path + "/" + Self.text(name)
                let status = try system(entryPath) { () throws(TreeFileSystemError) in
                    try fileSystem.status(of: name, in: directory)
                }
                var header = EntryHeader()
                header.depth = depth
                header.name = Data(name)
                switch status.kind {
                case .directory:
                    header.type = .directory
                    header.mode = status.permissions
                    try emit(header, path: entryPath)
                    let child = try system(entryPath) { () throws(TreeFileSystemError) in
                        try fileSystem.openDirectory(name, in: directory)
                    }
                    defer { fileSystem.close(child) }
                    try walk(child, depth: depth + 1, path: entryPath)
                case .regular:
                    header.type = .file
                    header.mode = status.permissions
                    var plain = Kernova_V2_PlainStorage()
                    plain.size = UInt64(status.size)
                    header.plain = plain
                    try emit(header, path: entryPath)
                    let file = try system(entryPath) { () throws(TreeFileSystemError) in
                        try fileSystem.openFile(name, in: directory)
                    }
                    defer { fileSystem.close(file) }
                    try copy(file, size: UInt64(status.size), path: entryPath)
                case .symbolicLink:
                    header.type = .symlink
                    header.mode = UpdatePayloadPacker.symlinkMode
                    header.symlinkTarget = Data(
                        try system(entryPath) { () throws(TreeFileSystemError) in
                            try fileSystem.linkTarget(of: name, in: directory)
                        })
                    try emit(header, path: entryPath)
                default:
                    throw Failure(path: entryPath, detail: "the update profile carries no \(status.kind)")
                }
            }
        }

        /// Hands on the file's bytes, which must be the `size` it was found with.
        mutating func copy(_ file: Int32, size: UInt64, path: String) throws {
            var buffer = [UInt8](repeating: 0, count: ContainerEncoder.chunkByteCount)
            var copied: UInt64 = 0
            while true {
                let count = try buffer.withUnsafeMutableBytes { bytes in
                    try system(path) { () throws(TreeFileSystemError) in try fileSystem.read(file, into: bytes) }
                }
                guard count > 0 else { break }
                copied += UInt64(count)
                guard copied <= size else { throw Failure(path: path, detail: "grew while it was packed") }
                try records(path) { encoder throws(ContainerError) in try encoder.bytes(Data(buffer[0..<count])) }
            }
            guard copied == size else { throw Failure(path: path, detail: "shrank while it was packed") }
        }

        mutating func emit(_ header: EntryHeader, path: String) throws {
            try records(path) { encoder throws(ContainerError) in try encoder.entry(header) }
        }

        mutating func finish() throws {
            try records("") { encoder throws(ContainerError) in try encoder.end() }
        }

        private mutating func records(
            _ path: String, _ body: (inout ContainerEncoder) throws(ContainerError) -> Data
        ) throws {
            let bytes: Data
            do { bytes = try body(&encoder) } catch { throw Failure(path: path, detail: "\(error)") }
            if !bytes.isEmpty { try output(bytes) }
        }

        func system<Result>(_ path: String, _ call: () throws(TreeFileSystemError) -> Result) throws -> Result {
            do { return try call() } catch { throw Failure(path: path, detail: String(cString: strerror(error.code))) }
        }

        static func text(_ name: [UInt8]) -> String { String(decoding: name, as: UTF8.self) }
    }
}
#endif
