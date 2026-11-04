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
import Testing

@testable import KernovaTreeTransfer

/// Publishing a received item under the name the receiver chooses, by each path a volume allows.
@Suite("Publishing")
struct PublishTests {
    /// Each way a volume renames without replacing: as this one does, by a claim where it says it cannot, and by
    /// a claim where it refuses the flag.
    static let renames: [InterposedFileSystem.ExclusiveRename] = [.asTheVolume, .unsupported, .refused]

    @Test(
        "Keep Both counts in before the last extension, as NSString reads one",
        arguments: [
            ("report.pdf", "report 2.pdf"), ("archive.tar.gz", "archive.tar 2.gz"), (".hidden", ".hidden 2"),
            ("a.", "a. 2"), ("a..b", "a. 2.b"), ("folder", "folder 2"), ("a.b c", "a.b c 2"), ("a .b", "a  2.b"),
        ])
    func keepBothNames(_ name: String, _ second: String) {
        #expect(KeepBothName.candidate(bytes(name), 1) == bytes(name))
        #expect(KeepBothName.candidate(bytes(name), 2) == bytes(second))
        #expect(KeepBothName.candidate(bytes("report.pdf"), 11) == bytes("report 11.pdf"))
    }

    @Test("a FILE publishes under the receiver's name", arguments: renames)
    func fileTakesTheReceiversName(_ rename: InterposedFileSystem.ExclusiveRename) throws {
        let landing = try Landing(kernelContainment: true)
        let result = try publish(Self.fileContainer, .file, as: .exactly(bytes("chosen.txt")), rename, landing)
        #expect(result.success == bytes("chosen.txt"))
        #expect(try Self.contents(landing, "chosen.txt") == Data("hello".utf8))
        try landing.expectNothingOutside(landed: bytes("chosen.txt"))
    }

    @Test("a FOLDER publishes whole under the receiver's name", arguments: renames)
    func folderTakesTheReceiversName(_ rename: InterposedFileSystem.ExclusiveRename) throws {
        let landing = try Landing(kernelContainment: true)
        let result = try publish(Self.folderContainer, .folder, as: .exactly(bytes("Chosen")), rename, landing)
        #expect(result.success == bytes("Chosen"))
        #expect(try landing.landedEntries(bytes("Chosen")) == [".: directory", "./f: regular 1"].sorted())
        try landing.expectNothingOutside(landed: bytes("Chosen"))
    }

    @Test("an item at an exact path lands there, and its publish keeps that name", arguments: [false, true])
    func exactPathKeepsItsName(_ folder: Bool) throws {
        let landing = try Landing(kernelContainment: true)
        let name = folder ? "Chosen" : "chosen.txt"
        let receiver = TreeReceiver(
            exactPath: bytes(landing.destinationPath + "/" + name), accepting: acceptance(folder ? .folder : .file),
            decodingWorkers: 0, fileSystem: POSIXTreeFileSystem())
        let result = Result { () throws(TreeWriteFailure) in
            try receiver.receive(folder ? Self.folderContainer : Self.fileContainer)
            try receiver.finish()
            return try receiver.publish()
        }
        #expect(result.success == bytes(name))
        try landing.expectNothingOutside(landed: bytes(name))
    }

    @Test("an exact path that is not absolute, or ends in no name, creates nothing", arguments: ["chosen.txt", "/"])
    func exactPathRefused(_ path: String) throws {
        let receiver = TreeReceiver(
            exactPath: bytes(path), accepting: acceptance(.file), decodingWorkers: 0, fileSystem: POSIXTreeFileSystem())
        let failure = #expect(throws: TreeWriteFailure.self) { try receiver.receive(Self.fileContainer) }
        #expect(failure?.reason == .container(.invalidName))
        if path != "/" { #expect(access(path, F_OK) != 0) }
    }

    @Test("Keep Both lands past every taken name, replacing none", arguments: renames)
    func keepBothCollides(_ rename: InterposedFileSystem.ExclusiveRename) throws {
        let landing = try Landing(kernelContainment: true)
        try Self.seed(landing, files: ["report.pdf", "report 2.pdf"], folders: ["Folder"])
        let file = try publish(Self.fileContainer, .file, as: .keepingBoth(bytes("report.pdf")), rename, landing)
        let folder = try publish(Self.folderContainer, .folder, as: .keepingBoth(bytes("Folder")), rename, landing)
        #expect(file.success == bytes("report 3.pdf"))
        #expect(folder.success == bytes("Folder 2"))
        #expect(try Self.contents(landing, "report 3.pdf") == Data("hello".utf8))
        for name in ["report.pdf", "report 2.pdf"] { #expect(try Self.contents(landing, name) == Data("seed".utf8)) }
        #expect(try landing.landedEntries(bytes("Folder")) == [".: directory"])
        #expect(try landing.landedEntries(bytes("Folder 2")) == [".: directory", "./f: regular 1"].sorted())
        #expect(
            try Self.names(landing) == ["Folder", "Folder 2", "report 2.pdf", "report 3.pdf", "report.pdf"].sorted())
    }

    @Test("an exact name that is taken fails EEXIST, leaving the taken item and nothing else", arguments: renames)
    func exactNameTaken(_ rename: InterposedFileSystem.ExclusiveRename) throws {
        let landing = try Landing(kernelContainment: true)
        try Self.seed(landing, files: ["taken"], folders: ["taken folder"])
        let file = try publish(Self.fileContainer, .file, as: .exactly(bytes("taken")), rename, landing)
        let folder = try publish(Self.folderContainer, .folder, as: .exactly(bytes("taken folder")), rename, landing)
        for result in [file, folder] {
            guard case .system(let error)? = result.failure?.reason else {
                Issue.record("\(result)")
                continue
            }
            #expect(error.code == EEXIST)
        }
        #expect(try Self.contents(landing, "taken") == Data("seed".utf8))
        #expect(try landing.landedEntries(bytes("taken folder")) == [".: directory"])
        #expect(try Self.names(landing) == ["taken", "taken folder"])
    }

    @Test("Keep Both counts no name past the name limit: a taken name that has no room fails ENAMETOOLONG")
    func keepBothWithinTheNameLimit() throws {
        let landing = try Landing(kernelContainment: true)
        let longest = String(repeating: "n", count: 255)
        try Self.seed(landing, files: [longest], folders: [])
        let result = try publish(Self.fileContainer, .file, as: .keepingBoth(bytes(longest)), .asTheVolume, landing)
        #expect(result.failure?.reason == .system(TreeFileSystemError(code: ENAMETOOLONG)))
        #expect(try Self.names(landing) == [longest])
    }

    @Test("publishing before the container finished fails, and a name that is not one component is refused")
    func publishOnlyAValidNameOfAFinishedItem() throws {
        let landing = try Landing(kernelContainment: true)
        let early = try landing.receiver(acceptance(.file), as: bytes("x"))
        try early.receive(Self.fileContainer)
        #expect(Result { () throws(TreeWriteFailure) in try early.publish() }.failure != nil)
        for name in ["", ".", "..", "a/b"] {
            let result = try publish(Self.fileContainer, .file, as: .keepingBoth(bytes(name)), .asTheVolume, landing)
            #expect(result.failure?.reason == .container(.invalidName), "\(name)")
        }
        #expect(try Self.names(landing).isEmpty)
    }

    // MARK: - Support

    /// A FILE container, its own entry unnamed, carrying `hello`.
    static var fileContainer: Data {
        var container = RawContainer()
        container.file(file("", depth: 0, size: 5), Data("hello".utf8))
        container.end()
        return container.data
    }

    /// A FOLDER container, its own entry unnamed, holding the file `f`.
    static var folderContainer: Data {
        var container = RawContainer()
        container.header(directory("", depth: 0))
        container.file(file("f", depth: 1, size: 1), Data("f".utf8))
        container.end()
        return container.data
    }

    /// Lands `container` of `storage` in `landing`'s destination through a volume that renames as `rename` says,
    /// and publishes it as `name`.
    private func publish(
        _ container: Data, _ storage: Representation.Storage, as name: PublishName,
        _ rename: InterposedFileSystem.ExclusiveRename, _ landing: Landing
    ) throws -> Result<[UInt8], TreeWriteFailure> {
        let fileSystem = InterposedFileSystem(exclusiveRename: rename)
        let receiver = TreeReceiver(
            name: name, accepting: acceptance(storage), decodingWorkers: 0, fileSystem: fileSystem,
            destination: try landing.openDestination(), destinationPathByteCount: landing.destinationPath.utf8.count)
        return Result { () throws(TreeWriteFailure) in
            try receiver.receive(container)
            try receiver.finish()
            return try receiver.publish()
        }
    }

    private static func seed(_ landing: Landing, files: [String], folders: [String]) throws {
        for name in files {
            let descriptor = open(landing.destinationPath + "/" + name, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            try #require(descriptor >= 0)
            _ = "seed".withCString { write(descriptor, $0, 4) }
            close(descriptor)
        }
        for name in folders { try #require(mkdir(landing.destinationPath + "/" + name, 0o755) == 0) }
    }

    private static func contents(_ landing: Landing, _ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: landing.destinationPath + "/" + name))
    }

    private static func names(_ landing: Landing) throws -> [String] {
        let destination = try landing.openDestination()
        defer { landing.fileSystem.close(destination) }
        return try landing.fileSystem.names(in: destination).map { String(decoding: $0, as: UTF8.self) }.sorted()
    }
}

extension Result {
    fileprivate var success: Success? { try? get() }
}
#endif
