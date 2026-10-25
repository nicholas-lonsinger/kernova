import Darwin
import Foundation
import KernovaTestSupport
import System
import Testing
import UniformTypeIdentifiers

@testable import KernovaKit

/// Moving a pulled item out of staging: to the exact URL a Mac destination
/// asked for, or under a Finder-style unique name in a folder.
@Suite("StagedItemLanding", .caseScoped)
struct StagedItemLandingTests {
    private let scratch = TestScratchDirectory(prefix: "StagedItemLandingTests")

    private func staged(_ name: String, bytes: Data = Data("payload".utf8)) throws
        -> ClipboardContent.Representation
    {
        let staging = scratch.url.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let url = staging.appendingPathComponent(name)
        try bytes.write(to: url)
        return ClipboardContent.Representation(
            uti: "public.data", fileURL: url, byteCount: bytes.count, filename: name)
    }

    private func destinationFolder() throws -> URL {
        let folder = scratch.url.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("an item lands at exactly the URL it is given, leaving staging empty")
    func landsAtTheExactURL() throws {
        let representation = try staged("report.pdf")
        let destination = try destinationFolder().appendingPathComponent("Renamed.pdf")

        try StagedItemLanding.land(representation, at: destination)

        #expect(try Data(contentsOf: destination) == Data("payload".utf8))
        #expect(!FileManager.default.fileExists(atPath: try #require(representation.fileURL).path))
    }

    @Test("an exact landing never replaces what is already there")
    func exactLandingRefusesAnExistingItem() throws {
        let representation = try staged("report.pdf")
        let destination = try destinationFolder().appendingPathComponent("report.pdf")
        try Data("theirs".utf8).write(to: destination)

        #expect(throws: (any Error).self) {
            try StagedItemLanding.land(representation, at: destination)
        }
        #expect(try Data(contentsOf: destination) == Data("theirs".utf8))
    }

    @Test("a failed move is thrown, leaving the staged item where it was")
    func failedMoveThrows() throws {
        let representation = try staged("report.pdf")
        let destination = scratch.url.appendingPathComponent("missing/report.pdf")

        let error = #expect(throws: POSIXError.self) {
            try StagedItemLanding.land(representation, at: destination)
        }
        #expect(error?.code == .ENOENT)
        #expect(FileManager.default.fileExists(atPath: try #require(representation.fileURL).path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    /// A staged folder named `name` holding `sub/a.txt`.
    private func stagedTree(_ name: String) throws -> URL {
        let tree = scratch.url.appendingPathComponent("staging/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tree.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: tree.appendingPathComponent("sub/a.txt"))
        return tree
    }

    /// A rename that fails with `EXDEV` stands in for another volume.
    @Test(
        "a folder whose own mode withholds write from its owner lands by rename, or by copy, with that mode",
        arguments: [nil, Errno.improperLink])
    func unwritableFolderLandsWithItsMode(renameFailure: Errno?) throws {
        let tree = try stagedTree("Locked")
        let inode = try linkStatus(tree.path).st_ino
        try #require(chmod(tree.path, 0o555) == 0)
        let destination = try destinationFolder().appendingPathComponent("Locked")

        try StagedItemLanding.land(
            tree, at: destination, on: InterposedArchiveVolume(failingRenamesWith: renameFailure))

        #expect(try linkStatus(destination.path).st_mode & 0o7777 == 0o555)
        #expect(try Data(contentsOf: destination.appendingPathComponent("sub/a.txt")) == Data("one".utf8))
        #expect((try linkStatus(destination.path).st_ino == inode) == (renameFailure == nil))
        #expect(!FileManager.default.fileExists(atPath: tree.path))
    }

    @Test("a rename failing for a reason other than another volume is thrown, and nothing is copied")
    func otherRenameFailureIsThrown() throws {
        let tree = try stagedTree("Tree")
        let destination = try destinationFolder().appendingPathComponent("Tree")

        let error = #expect(throws: POSIXError.self) {
            try StagedItemLanding.land(
                tree, at: destination, on: InterposedArchiveVolume(failingRenamesWith: .ioError))
        }
        #expect(error?.code == .EIO)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: tree.appendingPathComponent("sub/a.txt")) == Data("one".utf8))
    }

    @Test("on one volume, a folder lands by rename, keeping its inode")
    func sameVolumeLandingIsARename() throws {
        let tree = try stagedTree("Photos")
        let inode = try linkStatus(tree.path).st_ino
        let representation = ClipboardContent.Representation(
            uti: "public.folder", fileURL: tree, byteCount: 3, filename: "Photos", isDirectory: true)
        let destination = try destinationFolder().appendingPathComponent("Photos")

        try StagedItemLanding.land(representation, at: destination)

        #expect(try linkStatus(destination.path).st_ino == inode)
        #expect(!FileManager.default.fileExists(atPath: tree.path))
    }

    // MARK: - Across volumes

    /// A copy `removeItem` could not take out of staging: a read-only folder
    /// holding a file.
    @Test(
        "across volumes, or where a rename would replace, a folder holding a read-only folder copies whole, symlinks as themselves, and leaves staging",
        arguments: [Errno.improperLink, .notSupported])
    func folderCopiesAcrossVolumes(renameFailure: Errno) throws {
        let fm = FileManager.default
        let tree = try stagedTree("Tree")
        let locked = tree.appendingPathComponent("locked", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: false)
        try Data("inside".utf8).write(to: locked.appendingPathComponent("inside.txt"))
        try #require(chmod(locked.path, 0o555) == 0)
        // Dangling, so following it instead of copying it would fail.
        try fm.createSymbolicLink(
            atPath: tree.appendingPathComponent("dangling").path, withDestinationPath: "nowhere")
        let destination = try destinationFolder().appendingPathComponent("Tree")

        try StagedItemLanding.land(
            tree, at: destination, on: InterposedArchiveVolume(failingRenamesWith: renameFailure))

        #expect(try Data(contentsOf: destination.appendingPathComponent("sub/a.txt")) == Data("one".utf8))
        #expect(
            try Data(contentsOf: destination.appendingPathComponent("locked/inside.txt")) == Data("inside".utf8))
        #expect(try linkStatus(destination.appendingPathComponent("locked").path).st_mode & 0o7777 == 0o555)
        let link = destination.appendingPathComponent("dangling").path
        #expect(try linkStatus(link).st_mode & S_IFMT == S_IFLNK)
        #expect(try fm.destinationOfSymbolicLink(atPath: link) == "nowhere")
        #expect(!fm.fileExists(atPath: tree.path))
    }

    @Test("across volumes, a file copies byte for byte and leaves staging")
    func fileCopiesAcrossVolumes() throws {
        let representation = try staged("report.pdf")
        let source = try #require(representation.fileURL)
        let destination = try destinationFolder().appendingPathComponent("Renamed.pdf")

        try StagedItemLanding.land(
            source, at: destination, on: InterposedArchiveVolume(failingRenamesWith: .improperLink))

        #expect(try Data(contentsOf: destination) == Data("payload".utf8))
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test("across volumes, an existing item is never replaced, and the staged item stays", arguments: [false, true])
    func copyRefusesAnExistingItem(stagedIsFolder: Bool) throws {
        let source = stagedIsFolder ? try stagedTree("Item") : try #require(try staged("Item").fileURL)
        let destination = try destinationFolder().appendingPathComponent("Item")
        try Data("theirs".utf8).write(to: destination)

        #expect(throws: (any Error).self) {
            try StagedItemLanding.land(
                source, at: destination, on: InterposedArchiveVolume(failingRenamesWith: .improperLink))
        }
        #expect(try Data(contentsOf: destination) == Data("theirs".utf8))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("landing in a folder counts the name up the way Finder keeps both")
    func folderLandingUniquifies() throws {
        let folder = try destinationFolder()
        try Data("theirs".utf8).write(to: folder.appendingPathComponent("report.pdf"))

        let landed = try StagedItemLanding.land(
            try staged("report.pdf"), inDirectory: folder, named: "report.pdf")

        #expect(landed.lastPathComponent == "report 2.pdf")
        #expect(try Data(contentsOf: landed) == Data("payload".utf8))
        #expect(
            try Data(contentsOf: folder.appendingPathComponent("report.pdf"))
                == Data("theirs".utf8))
    }

    @Test("a folder landing creates the folder and keeps the staged name when none is given")
    func folderLandingCreatesTheFolder() throws {
        let folder = scratch.url.appendingPathComponent("not-yet", isDirectory: true)

        let landed = try StagedItemLanding.land(
            try staged("kept.bin"), inDirectory: folder, named: "")

        #expect(landed == folder.appendingPathComponent("kept.bin"))
        #expect(FileManager.default.fileExists(atPath: landed.path))
    }

    @Test("a folder item lands whole, tree and all")
    func directoryLandsWhole() throws {
        let tree = scratch.url.appendingPathComponent("staging/Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: tree.appendingPathComponent("one.jpg"))
        // A folder arrives already extracted, as the receiver delivers it.
        let representation = ClipboardContent.Representation(
            uti: "public.folder", fileURL: tree, byteCount: 3, filename: "Photos",
            isDirectory: true)
        let destination = try destinationFolder().appendingPathComponent("Photos")

        try StagedItemLanding.land(representation, at: destination)

        #expect(
            try Data(contentsOf: destination.appendingPathComponent("one.jpg"))
                == Data("one".utf8))
    }

    @Test("a representation with no staged file is refused")
    func inMemoryRepresentationIsRefused() throws {
        let representation = ClipboardContent.Representation(
            uti: "public.data", data: Data("x".utf8), filename: "x.bin")

        #expect(throws: CocoaError.self) {
            try StagedItemLanding.land(
                representation, at: try destinationFolder().appendingPathComponent("x.bin"))
        }
    }
}

/// What the host keeps of a guest-supplied item name and type: a single safe
/// path component, and a type a file promise accepts.
@Suite("ClipboardDraggedItem", .caseScoped)
struct ClipboardDraggedItemTests {
    @Test(
        "a hostile or empty name reduces to one safe path component",
        arguments: [
            ("../escape", false, "escape"), ("a/b", false, "b"), ("", false, "File"),
            (".", false, "File"), ("..", false, "File"), ("", true, "Folder"),
            ("Photos", true, "Photos"), ("report.pdf", false, "report.pdf"),
        ])
    func safeFilename(declared: String, isDirectory: Bool, expected: String) {
        #expect(ClipboardDraggedItem.safeFilename(declared, isDirectory: isDirectory) == expected)
    }

    @Test(
        "a type is kept only when it suits the item's kind",
        arguments: [
            ("public.png", false, "public.png"),
            ("public.folder", false, "public.data"),
            ("not a type at all", false, "public.data"),
            ("public.item", false, "public.data"),
            ("public.jpeg", true, "public.folder"),
            ("com.apple.application-bundle", true, "com.apple.application-bundle"),
            ("public.folder", true, "public.folder"),
            ("", true, "public.folder"),
        ])
    func usableType(declared: String, isDirectory: Bool, expected: String) {
        #expect(
            ClipboardDraggedItem.usableType(declared, isDirectory: isDirectory).identifier
                == expected)
    }

    @Test("an item carries its index and its kind as declared")
    func carriesTheDeclaredFacts() {
        let item = ClipboardDraggedItem(
            repIndex: 2,
            declared: RepInfo(
                uti: "public.folder", byteCount: 77, filename: "../Tree", isInline: true,
                isDirectory: true
            ).wire, isPromised: false)

        #expect(item.repIndex == 2)
        #expect(item.isDirectory)
        #expect(item.filename == "Tree")
        #expect(item.type.identifier == "public.folder")
    }
}
