import Foundation
import KernovaTestSupport
import Testing
import UniformTypeIdentifiers

@testable import KernovaKit

/// Moving a pulled item out of staging: to the exact URL a Mac destination
/// asked for, or under a Finder-style unique name in a folder, by rename or —
/// across volumes — by copy.
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

    @Test("a cross-device rename falls back to copying, then frees the staged copy")
    func crossDeviceMoveCopies() throws {
        let representation = try staged("report.pdf")
        let destination = try destinationFolder().appendingPathComponent("report.pdf")
        let crossDevice = NSError(
            domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))])

        try StagedItemLanding.land(representation, at: destination) { _, _ in throw crossDevice }

        #expect(try Data(contentsOf: destination) == Data("payload".utf8))
        #expect(!FileManager.default.fileExists(atPath: try #require(representation.fileURL).path))
    }

    @Test("any other failed move is thrown, leaving the staged item where it was")
    func otherMoveFailuresThrow() throws {
        let representation = try staged("report.pdf")
        let destination = try destinationFolder().appendingPathComponent("report.pdf")

        #expect(throws: CocoaError.self) {
            try StagedItemLanding.land(representation, at: destination) { _, _ in
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        #expect(FileManager.default.fileExists(atPath: try #require(representation.fileURL).path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
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

    @Test("an item carries its index, its size, and its kind as declared")
    func carriesTheDeclaredFacts() {
        let item = ClipboardDraggedItem(
            repIndex: 2,
            declared: RepInfo(
                uti: "public.folder", byteCount: 77, filename: "../Tree", isInline: true,
                isDirectory: true
            ).wire)

        #expect(item.repIndex == 2)
        #expect(item.byteCount == 77)
        #expect(item.isDirectory)
        #expect(item.filename == "Tree")
        #expect(item.type.identifier == "public.folder")
    }
}
