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
import Testing

@testable import KernovaTreeTransfer

/// What lands, and what this OS refuses to land.
@Suite("Tree landing")
struct TreeLandingTests {
    private static func contents(of path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    @Test("a FILE representation lands under its own name with its bytes, mode and time", arguments: bothLayers)
    func fileLands(kernelContainment: Bool) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        var header = file("report.txt", depth: 0, size: 5, mode: 0o640)
        header.modificationTime.seconds = 1_700_000_000
        header.modificationTime.nanoseconds = 5000
        var container = RawContainer()
        container.file(header, Data("hello".utf8))
        container.end()
        #expect(try landing.land(container.data, accepting: acceptance(.file)).get() == bytes("report.txt"))
        let path = landing.destinationPath + "/report.txt"
        #expect(try Self.contents(of: path) == Data("hello".utf8))
        let status = try landing.fileSystem.status(of: bytes(path), in: AT_FDCWD)
        #expect(status.permissions == 0o640)
        #expect(status.modificationTime == FileTime(seconds: 1_700_000_000, nanoseconds: 5000))
        try landing.expectNothingOutside(landed: bytes("report.txt"))
    }

    @Test(
        "a folder lands whole: directories read-only and unsearchable filled before their modes, symlinks unfollowed",
        arguments: bothLayers)
    func folderLands(kernelContainment: Bool) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        var container = RawContainer()
        container.header(directory("r", depth: 0, mode: 0o555))
        container.header(directory("sealed", depth: 1, mode: 0))
        container.file(file("inner", depth: 2, size: 2, mode: 0o444), Data("in".utf8))
        container.header(symlinkEntry("out", depth: 1, target: landing.outsidePath + "/sentinel"))
        container.file(file("big", depth: 1, size: 3 << 20), pattern(3 << 20))
        container.end()
        #expect(try landing.land(container.data, pieceSize: 4096).get() == bytes("r"))
        #expect(
            try landing.landedEntries(bytes("r"))
                == [
                    ".: directory", "./sealed: directory", "./sealed/inner: regular 2",
                    "./out: symlink -> \(landing.outsidePath)/sentinel", "./big: regular \(3 << 20)",
                ].sorted())
        let r = landing.destinationPath + "/r"
        #expect(try Self.contents(of: r + "/big") == pattern(3 << 20))
        for (path, mode) in [(r, UInt32(0o555)), (r + "/sealed", 0)] {
            #expect(try landing.fileSystem.status(of: bytes(path), in: AT_FDCWD).permissions == mode, "\(path)")
        }
        try landing.expectNothingOutside(landed: bytes("r"))
    }

    @Test("more small files than one batch takes land, each with its own bytes", arguments: bothLayers)
    func batchesLandInOrder(kernelContainment: Bool) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        let count = FolderBatch.entryBudget * 2 + 7
        var container = RawContainer()
        container.header(directory("r", depth: 0))
        for index in 0..<count {
            container.file(file("f\(index)", depth: 1, size: 3), Data("\(index % 1000)".utf8.prefix(3)).padded(to: 3))
        }
        container.end()
        #expect(try landing.land(container.data).get() == bytes("r"))
        #expect(try landing.landedEntries(bytes("r")).count == count + 1)
        #expect(try Self.contents(of: landing.destinationPath + "/r/f300") == Data("300".utf8))
    }

    @Test("a zero run reads back as zeros, and leaves a hole where the volume makes them", arguments: bothLayers)
    func zeroRunsBecomeHoles(kernelContainment: Bool) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        let run: UInt64 = 8 << 20
        var container = RawContainer()
        container.header(file("sparse", depth: 0, size: 5 + run + 5))
        container.chunk(Data("head!".utf8))
        container.zeros(run)
        container.chunk(Data("tail!".utf8))
        container.end()
        #expect(try landing.land(container.data, accepting: acceptance(.file)).get() == bytes("sparse"))
        let path = landing.destinationPath + "/sparse"
        let landed = try Self.contents(of: path)
        #expect(landed == Data("head!".utf8) + Data(count: Int(run)) + Data("tail!".utf8))
        var status = stat()
        try #require(stat(path, &status) == 0)
        #expect(Int64(status.st_blocks) * 512 < Int64(run) / 2, "\(status.st_blocks) blocks")
    }

    @Test("an entry whose path would pass PATH_MAX is refused by name before it is created", arguments: bothLayers)
    func pathMaxIsRefused(kernelContainment: Bool) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        let name = String(repeating: "d", count: 200)
        let fits = (Int(PATH_MAX) - 1 - landing.destinationPath.utf8.count) / 201
        var container = RawContainer()
        container.header(directory(name, depth: 0))
        for depth in 1...fits { container.header(directory(name, depth: UInt32(depth))) }
        container.end()
        let failure = try #require(try landing.land(container.data).failure)
        #expect(failure.reason == .refused(.init(code: ENAMETOOLONG)))
        #expect(failure.path == Array(repeating: bytes(name), count: fits + 1))
        try landing.expectNothingOutside()
    }

    @Test("a name that is not UTF-8 is refused on Darwin, where APFS stores only UTF-8, and lands on Linux")
    func nonUTF8Names() throws {
        let landing = try Landing(kernelContainment: true)
        let name: [UInt8] = [0x66, 0xFF, 0x66]
        var container = RawContainer()
        container.header(directory("r", depth: 0))
        container.file(file(name, depth: 1, size: 1), Data("x".utf8))
        container.end()
        let result = try landing.land(container.data)
        #if canImport(Darwin)
        #expect(result.failure == TreeWriteFailure(path: [bytes("r"), name], reason: .refused(.init(code: EILSEQ))))
        #expect(result.failure?.wireError.code == .itemUnpackRefused)
        #expect(result.failure?.wireError.item.path == [Data("r".utf8), Data(name)])
        try landing.expectNothingOutside()
        #else
        #expect(try result.get() == bytes("r"))
        #expect(try landing.landedEntries(bytes("r")) == [".: directory", "./f%fff: regular 1"].sorted())
        #endif
    }

    #if canImport(Darwin)
    @Test("Finder tags, the hidden flag and the birth time land on Darwin, on a file, a folder and a symlink")
    func darwinMetadataLands() throws {
        let landing = try Landing(kernelContainment: true)
        var tags = Kernova_V2_Xattr()
        tags.name = Data("com.apple.metadata:_kMDItemUserTags".utf8)
        tags.value = Data("bplist-ish".utf8)
        func tagged(_ header: EntryHeader) -> EntryHeader {
            var header = header
            header.darwinFlags = UInt32(UF_HIDDEN)
            header.birthTime.seconds = 1_600_000_000
            header.xattrs = [tags]
            return header
        }
        var container = RawContainer()
        container.header(tagged(directory("r", depth: 0)))
        container.file(tagged(file("file", depth: 1, size: 1)), Data("t".utf8))
        container.header(tagged(symlinkEntry("link", depth: 1, target: "file")))
        container.end()
        #expect(try landing.land(container.data).get() == bytes("r"))
        for name in ["", "/file", "/link"] {
            let path = landing.destinationPath + "/r" + name
            let status = try landing.fileSystem.status(of: bytes(path), in: AT_FDCWD)
            #expect(status.flags & UInt32(UF_HIDDEN) != 0, "\(path)")
            #expect(status.birthTime?.seconds == 1_600_000_000, "\(path)")
            var value = [UInt8](repeating: 0, count: 64)
            let count = getxattr(path, "com.apple.metadata:_kMDItemUserTags", &value, value.count, 0, XATTR_NOFOLLOW)
            #expect(count == 10, "\(path)")
        }
    }
    #endif
}

extension Data {
    fileprivate func padded(to count: Int) -> Data {
        self + Data(repeating: 0x2E, count: Swift.max(0, count - self.count))
    }
}
#endif
