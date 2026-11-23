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
}
#endif
