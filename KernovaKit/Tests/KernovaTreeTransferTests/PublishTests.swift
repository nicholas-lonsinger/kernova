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
        "an exact-path publish that finds another item at its path fails moved and leaves both",
        arguments: [false, true])
    func exactPathMovedLeavesTheOther(_ folder: Bool) throws {
        let landing = try Landing(kernelContainment: true)
        let path = landing.destinationPath + "/chosen"
        let receiver = TreeReceiver(
            exactPath: bytes(path), accepting: acceptance(folder ? .folder : .file), decodingWorkers: 0,
            fileSystem: POSIXTreeFileSystem())
        try receiver.receive(folder ? Self.folderContainer : Self.fileContainer)
        try receiver.finish()
        // The user moves the landing item away and puts their own item under the same name.
        #expect(rename(path, landing.destinationPath + "/moved-away") == 0)
        let own = folder ? path + "/own.txt" : path
        if folder { #expect(mkdir(path, 0o755) == 0) }
        try Data("the user's own".utf8).write(to: URL(fileURLWithPath: own))
        let result = Result { () throws(TreeWriteFailure) in try receiver.publish() }
        #expect(result.failure?.reason == .moved)
        #expect(access(own, F_OK) == 0, "the publish removed an item the writer did not create")
        #expect(access(landing.destinationPath + "/moved-away", F_OK) == 0)
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
