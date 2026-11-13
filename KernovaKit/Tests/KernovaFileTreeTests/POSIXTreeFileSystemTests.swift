#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import KernovaFileTree
import KernovaPortableTestSupport
import Testing

/// The calls against this machine's own volume. Nothing here rests on a
/// permission check, so the suite means the same run as root, as the Linux CI
/// container runs it.
@Suite("POSIXTreeFileSystem")
struct POSIXTreeFileSystemTests {
    private let scratch: PortableScratchDirectory

    init() throws {
        scratch = try PortableScratchDirectory(prefix: "tree-file-system")
    }

    private static func bytes(_ name: String) -> [UInt8] { Array(name.utf8) }

    /// Opens the scratch directory as a tree's root.
    private func openScratch(on fileSystem: POSIXTreeFileSystem) throws -> Int32 {
        try fileSystem.openDirectory(Self.bytes(scratch.path), in: AT_FDCWD)
    }

    /// Whether this kernel refuses, under its containment, a name that leaves
    /// the directory it is opened in.
    private static var kernelContains: Bool {
        #if canImport(Darwin)
        if #available(macOS 15.4, *) { return true }
        return false
        #else
        return true
        #endif
    }

    @Test(
        "with the kernel's containment, a name that leaves the directory is refused; without it, it opens",
        arguments: [true, false])
    func kernelContainmentRefusesLeavingNames(kernelContainment: Bool) throws {
        let fileSystem = POSIXTreeFileSystem(kernelContainment: kernelContainment)
        try #require(mkdir(scratch.path + "/inner", 0o755) == 0)
        let top = try openScratch(on: fileSystem)
        defer { fileSystem.close(top) }
        let inner = try fileSystem.openDirectory(Self.bytes("inner"), in: top)
        defer { fileSystem.close(inner) }

        let refused = kernelContainment && Self.kernelContains
        for name in ["..", "/"] {
            do {
                let opened = try fileSystem.openDirectory(Self.bytes(name), in: inner)
                fileSystem.close(opened)
                #expect(!refused, "\(name) opened under the kernel's containment")
            } catch {
                #expect(refused, "\(name): \(error)")
            }
        }

        // The cursor's own way up is unaffected.
        let parent = try fileSystem.openParent(of: inner)
        defer { fileSystem.close(parent) }
        #expect(try fileSystem.status(of: parent).inode == (try fileSystem.status(of: top).inode))
    }

    @Test(
        "a symlink is never opened as a directory or a file, with or without the kernel's containment",
        arguments: [true, false])
    func symlinksAreRefused(kernelContainment: Bool) throws {
        let fileSystem = POSIXTreeFileSystem(kernelContainment: kernelContainment)
        try #require(mkdir(scratch.path + "/target", 0o755) == 0)
        try #require(symlink("target", scratch.path + "/link") == 0)
        let top = try openScratch(on: fileSystem)
        defer { fileSystem.close(top) }

        #expect(throws: TreeFileSystemError.self) { try fileSystem.openDirectory(Self.bytes("link"), in: top) }
        #expect(throws: TreeFileSystemError.self) { try fileSystem.openFile(Self.bytes("link"), in: top) }
        #expect(try fileSystem.status(of: Self.bytes("link"), in: top).kind == .symbolicLink)
        #expect(try fileSystem.linkTarget(of: Self.bytes("link"), in: top) == Self.bytes("target"))
    }

    @Test("opening a file for appending never creates it, and never opens a symlink to one")
    func appendingNeverCreates() throws {
        let fileSystem = POSIXTreeFileSystem()
        try #require(close(open(scratch.path + "/file", O_WRONLY | O_CREAT, 0o600)) == 0)
        try #require(symlink("file", scratch.path + "/link") == 0)
        let top = try openScratch(on: fileSystem)
        defer { fileSystem.close(top) }
        let refusal = #expect(throws: TreeFileSystemError.self) {
            try fileSystem.openFileForAppending(Self.bytes("missing"), in: top)
        }
        #expect(refusal?.code == ENOENT)
        #expect(throws: TreeFileSystemError.self) { try fileSystem.status(of: Self.bytes("missing"), in: top) }
        #expect(throws: TreeFileSystemError.self) { try fileSystem.openFileForAppending(Self.bytes("link"), in: top) }
    }

    @Test(
        "a resource fork written in positional pieces reads back in pieces where the OS keeps one, and is refused where it keeps none"
    )
    func resourceForkInPieces() throws {
        let fileSystem = POSIXTreeFileSystem()
        let top = try openScratch(on: fileSystem)
        defer { fileSystem.close(top) }
        let descriptor = try fileSystem.createFile(Self.bytes("forked"), in: top)
        defer { fileSystem.close(descriptor) }
        let fork = (0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) }
        var held = true
        for start in stride(from: 0, to: fork.count, by: 65_536) {
            let piece = fork[start..<min(start + 65_536, fork.count)]
            held = try piece.withUnsafeBytes {
                try fileSystem.writeResourceFork(descriptor, from: $0, at: UInt64(start))
            }
            guard held else { break }
        }
        #if canImport(Darwin)
        #expect(held)
        #expect(try fileSystem.resourceForkSize(of: descriptor, showingCompression: false) == UInt64(fork.count))
        var read = [UInt8](repeating: 0, count: fork.count + 10)
        var offset = 0
        while true {
            let count = try read.withUnsafeMutableBytes { buffer in
                try fileSystem.readResourceFork(
                    descriptor,
                    into: UnsafeMutableRawBufferPointer(rebasing: buffer[offset..<min(offset + 100_000, buffer.count)]),
                    at: UInt64(offset), showingCompression: false)
            }
            if count == 0 { break }
            offset += count
        }
        #expect(Array(read[..<offset]) == fork)
        #expect(try fileSystem.compressedStorage(of: descriptor, maxByteCount: 3_802) == nil)
        #else
        #expect(!held)
        #expect(try fileSystem.resourceForkSize(of: descriptor, showingCompression: false) == 0)
        #endif
    }
}
#endif
