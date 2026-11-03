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

    @Test("an entry's status, the names in a directory, and a file's bytes")
    func statusNamesAndReads() throws {
        let fileSystem = POSIXTreeFileSystem()
        try #require(mkdir(scratch.path + "/dir", 0o751) == 0)
        try #require(mkfifo(scratch.path + "/pipe", 0o640) == 0)
        let file = open(scratch.path + "/file", O_WRONLY | O_CREAT | O_EXCL, 0o604)
        try #require(file >= 0)
        try #require(write(file, "hello", 5) == 5)
        _ = close(file)
        try #require(chmod(scratch.path + "/dir", 0o751) == 0)
        try #require(chmod(scratch.path + "/file", 0o604) == 0)

        let top = try openScratch(on: fileSystem)
        defer { fileSystem.close(top) }
        #expect(
            try fileSystem.names(in: top).sorted { $0.lexicographicallyPrecedes($1) }
                == ["dir", "file", "pipe"].map(Self.bytes))

        let directory = try fileSystem.status(of: Self.bytes("dir"), in: top)
        #expect(directory.kind == .directory && directory.permissions == 0o751)
        #expect(try fileSystem.status(of: Self.bytes("pipe"), in: top).kind == .fifo)
        let status = try fileSystem.status(of: Self.bytes("file"), in: top)
        #expect(status.kind == .regular && status.permissions == 0o604 && status.size == 5)

        // A FIFO opens at once rather than waiting for a writer.
        let pipe = try fileSystem.openFile(Self.bytes("pipe"), in: top)
        fileSystem.close(pipe)

        let opened = try fileSystem.openFile(Self.bytes("file"), in: top)
        defer { fileSystem.close(opened) }
        #expect(try fileSystem.status(of: opened) == status)
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = try buffer.withUnsafeMutableBytes { try fileSystem.read(opened, into: $0) }
        #expect(Array(buffer[..<count]) == Self.bytes("hello"))
        #expect(try buffer.withUnsafeMutableBytes { try fileSystem.read(opened, into: $0) } == 0)
    }

    @Test("a rename never replaces what has the new name")
    func renameIsExclusive() throws {
        let fileSystem = POSIXTreeFileSystem()
        for name in ["a", "b"] { try #require(mkdir(scratch.path + "/" + name, 0o755) == 0) }
        let top = try openScratch(on: fileSystem)
        defer { fileSystem.close(top) }

        #expect(throws: TreeFileSystemError(code: EEXIST)) {
            try fileSystem.rename(Self.bytes("a"), in: top, to: Self.bytes("b"), in: top)
        }
        try fileSystem.rename(Self.bytes("a"), in: top, to: Self.bytes("c"), in: top)
        #expect(try fileSystem.names(in: top).count == 2)
        #expect(try fileSystem.status(of: Self.bytes("c"), in: top).kind == .directory)
    }

    /// Linux's `PATH_MAX` is 4,096 and Darwin's 1,024, so 25 names of 200
    /// bytes outrun both.
    @Test("the cursor goes down a chain longer than PATH_MAX and back up, removing it on the way")
    func cursorWalksPastPathMax() throws {
        let fileSystem = POSIXTreeFileSystem()
        let name = Self.bytes(String(repeating: "d", count: 200))
        let cName = name.map { CChar(bitPattern: $0) } + [0]
        let depth = 25
        let top = try openScratch(on: fileSystem)
        let topStatus = try fileSystem.status(of: top)
        var cursor = DirectoryCursor(fileSystem: fileSystem, descriptor: top, status: topStatus, frame: 0)
        for level in 1...depth {
            try #require(mkdirat(cursor.descriptor, cName, 0o755) == 0)
            let child = try fileSystem.openDirectory(name, in: cursor.descriptor)
            cursor.descend(into: child, status: try fileSystem.status(of: child), frame: level)
        }
        let bottom = cursor.frame
        #expect(bottom == depth)

        while !cursor.isAtTop {
            let left = try cursor.ascend()
            let level = cursor.frame
            #expect(left == level + 1)
            try fileSystem.remove(name, in: cursor.descriptor, isDirectory: true)
        }
        let at = cursor.descriptor
        #expect(try fileSystem.status(of: at).inode == topStatus.inode)
        #expect(try fileSystem.names(in: at).isEmpty)
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

    @Test(
        "a resource fork a ResourceForkWriter lands in 256 KiB pieces reads back whole and, on APFS, takes the blocks of one written whole",
        arguments: [300_000, 5_000_000])
    func resourceForkWriterBlocks(length: Int) throws {
        let fileSystem = POSIXTreeFileSystem()
        let top = try openScratch(on: fileSystem)
        defer { fileSystem.close(top) }
        let fork = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ ($0 >> 9)) }
        let pieced = try fileSystem.createFile(Self.bytes("pieced"), in: top)
        defer { fileSystem.close(pieced) }
        var writer = ResourceForkWriter(length: UInt64(length))
        var held = true
        for start in stride(from: 0, to: length, by: 262_144) {
            held = try fork[start..<min(start + 262_144, length)].withUnsafeBytes {
                try writer.append($0, to: pieced, on: fileSystem)
            }
            guard held else { break }
        }
        #if canImport(Darwin)
        #expect(held)
        #expect(writer.byteCount == UInt64(length))
        var read = [UInt8](repeating: 0, count: length)
        var offset = 0
        while offset < length {
            let count = try read.withUnsafeMutableBytes { buffer in
                try fileSystem.readResourceFork(
                    pieced, into: UnsafeMutableRawBufferPointer(rebasing: buffer[offset...]), at: UInt64(offset),
                    showingCompression: false)
            }
            try #require(count > 0)
            offset += count
        }
        #expect(read == fork)
        let whole = try fileSystem.createFile(Self.bytes("whole"), in: top)
        defer { fileSystem.close(whole) }
        #expect(try fork.withUnsafeBytes { try fileSystem.writeResourceFork(whole, from: $0, at: 0) })
        func forkBlocks(_ name: String) throws -> Int64 {
            var status = stat()
            try #require(stat(scratch.path + "/" + name + "/..namedfork/rsrc", &status) == 0)
            return Int64(status.st_blocks)
        }
        #expect(try forkBlocks("pieced") <= forkBlocks("whole"))
        #else
        #expect(!held)
        #expect(writer.byteCount == 0)
        #endif
    }

    @Test("the scratch volume stores compressed files on Darwin's APFS, and none on Linux")
    func volumeCompression() throws {
        let fileSystem = POSIXTreeFileSystem()
        let top = try openScratch(on: fileSystem)
        defer { fileSystem.close(top) }
        #if canImport(Darwin)
        #expect(try fileSystem.volumeStoresCompressedFiles(top))
        #else
        #expect(try !fileSystem.volumeStoresCompressedFiles(top))
        let descriptor = try fileSystem.createFile(Self.bytes("plain"), in: top)
        defer { fileSystem.close(descriptor) }
        #expect(throws: TreeFileSystemError(code: ENOTSUP)) { try fileSystem.setCompressedStorage([0], of: descriptor) }
        #expect(throws: TreeFileSystemError(code: ENOTSUP)) { try fileSystem.setCompressedFlags(0, of: descriptor) }
        #endif
    }
}
#endif
