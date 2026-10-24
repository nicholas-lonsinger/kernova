import Darwin
import Foundation
import KernovaSynchronization
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

    @Test(
        "a folder whose own mode withholds write from its owner lands by rename, or by copy, with that mode",
        arguments: [nil, Errno.improperLink])
    func unwritableFolderLandsWithItsMode(renameFailure: Errno?) throws {
        let tree = try stagedTree("Locked")
        let inode = try linkStatus(tree.path).st_ino
        try setAttributes(tree, mode: 0o555)
        let destination = try destinationFolder().appendingPathComponent("Locked")
        let trash = TrashStandIn(scratch.url)

        try StagedItemLanding.land(
            tree, at: destination, from: ClipboardArchiveLocalVolume(),
            to: InterposedArchiveVolume(failingRenamesWith: renameFailure), trash: trash.trash)

        #expect(try linkStatus(destination.path).st_mode & 0o7777 == 0o555)
        #expect(try Data(contentsOf: destination.appendingPathComponent("sub/a.txt")) == Data("one".utf8))
        #expect((try linkStatus(destination.path).st_ino == inode) == (renameFailure == nil))
        #expect(!FileManager.default.fileExists(atPath: tree.path))
        #expect(trash.trashed.isEmpty)
    }

    @Test("a rename failing for a reason other than another volume is thrown, and nothing is copied")
    func otherRenameFailureIsThrown() throws {
        let tree = try stagedTree("Tree")
        let destination = try destinationFolder().appendingPathComponent("Tree")
        let created = Locked(false)
        let target = InterposedArchiveVolume(failingRenamesWith: .ioError) { call throws(Errno) in
            switch call {
            case .makeDirectory, .createFile, .makeSymlink: created.withLock { $0 = true }
            default: break
            }
        }

        let error = #expect(throws: POSIXError.self) {
            try StagedItemLanding.land(
                tree, at: destination, from: ClipboardArchiveLocalVolume(), to: target, trash: { _ in })
        }
        #expect(error?.code == .EIO)
        #expect(!created.withLock { $0 })
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

    private static let creation = timespec(tv_sec: 981_173_106, tv_nsec: 111_111_111)
    private static let modification = timespec(tv_sec: 1_013_000_000, tv_nsec: 222_222_222)

    /// A staged folder named `name` holding `sub/a.txt`.
    private func stagedTree(_ name: String) throws -> URL {
        let tree = scratch.url.appendingPathComponent("staging/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tree.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: tree.appendingPathComponent("sub/a.txt"))
        return tree
    }

    /// Gives the item at `url` the test's times, and `mode` and `flags` when
    /// given, without following a symlink.
    private func setAttributes(_ url: URL, mode: mode_t? = nil, flags: UInt32? = nil) throws {
        let attributes: [ClipboardArchiveAttribute?] = [
            .creation(Self.creation), .modification(Self.modification), flags.map { .flags($0) },
            mode.map { .mode($0) },
        ]
        for attribute in attributes.compactMap({ $0 }) {
            try ClipboardArchiveLocalVolume().setAttribute(attribute, of: .name(Array(url.path.utf8), in: AT_FDCWD))
        }
    }

    /// Stands in for the Trash, so nothing reaches the user's: moves what it
    /// is handed into a folder of its own, or fails when `failure` is set.
    private final class TrashStandIn: Sendable {
        private let folder: URL
        private let failure: CocoaError?
        private let items = Locked<[URL]>([])

        /// What the landing handed over, in order.
        var trashed: [URL] { items.withLock { $0 } }

        init(_ scratch: URL, failingWith failure: CocoaError? = nil) {
            folder = scratch.appendingPathComponent("Trash", isDirectory: true)
            self.failure = failure
        }

        func trash(_ url: URL) throws {
            items.withLock { $0.append(url) }
            if let failure { throw failure }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        }

        /// The names in the stand-in's folder.
        func contents() throws -> [String] {
            guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(atPath: folder.path)
        }
    }

    private func expectAttributes(
        _ url: URL, mode: mode_t, flags: UInt32 = 0, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let status = try linkStatus(url.path)
        #expect(status.st_mode & 0o7777 == mode, "mode of \(url.lastPathComponent)", sourceLocation: sourceLocation)
        #expect(status.st_flags & flags == flags, "flags of \(url.lastPathComponent)", sourceLocation: sourceLocation)
        #expect(
            sameInstant(status.st_mtimespec, Self.modification), "mtime of \(url.lastPathComponent)",
            sourceLocation: sourceLocation)
        #expect(
            sameInstant(status.st_birthtimespec, Self.creation), "birth time of \(url.lastPathComponent)",
            sourceLocation: sourceLocation)
    }

    /// A rename that fails with `EXDEV` stands in for another volume.
    @Test("across volumes, a tree past PATH_MAX copies whole with its attributes and symlinks, and leaves staging")
    func deepTreeCopiesAcrossVolumes() throws {
        let fm = FileManager.default
        let staged = scratch.url.appendingPathComponent("staging/Tree", isDirectory: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        let payload = Data("at the bottom".utf8)
        let leaf = try makeDeepTree(
            under: staged, depth: 7, name: String(repeating: "n", count: 200), contents: payload)
        #expect(leaf.utf8.count > Int(PATH_MAX))
        let file = staged.appendingPathComponent("file.txt")
        try Data("f".utf8).write(to: file)
        try setAttributes(file, mode: 0o640, flags: UInt32(UF_HIDDEN))
        let locked = staged.appendingPathComponent("locked", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: false)
        try Data("inside".utf8).write(to: locked.appendingPathComponent("inside.txt"))
        try setAttributes(locked, mode: 0o555)
        // Dangling, so following it instead of copying it would fail.
        try fm.createSymbolicLink(
            atPath: staged.appendingPathComponent("dangling").path, withDestinationPath: "nowhere")
        try fm.createSymbolicLink(
            atPath: staged.appendingPathComponent("to-file").path, withDestinationPath: "file.txt")
        try setAttributes(staged, mode: 0o750, flags: UInt32(UF_HIDDEN))
        let destination = try destinationFolder().appendingPathComponent("Tree")
        let staging = InterposedArchiveVolume()
        let target = InterposedArchiveVolume(failingRenamesWith: .improperLink)
        let trash = TrashStandIn(scratch.url)

        try StagedItemLanding.land(staged, at: destination, from: staging, to: target, trash: trash.trash)

        #expect(readThroughDescriptors(leaf, under: destination) == payload)
        #expect(try Data(contentsOf: destination.appendingPathComponent("file.txt")) == Data("f".utf8))
        try expectAttributes(destination.appendingPathComponent("file.txt"), mode: 0o640, flags: UInt32(UF_HIDDEN))
        #expect(
            readThroughDescriptors("locked/inside.txt", under: destination) == Data("inside".utf8))
        try expectAttributes(destination.appendingPathComponent("locked"), mode: 0o555)
        try expectAttributes(destination, mode: 0o750, flags: UInt32(UF_HIDDEN))
        for (name, target) in [("dangling", "nowhere"), ("to-file", "file.txt")] {
            let link = destination.appendingPathComponent(name).path
            #expect(try linkStatus(link).st_mode & S_IFMT == S_IFLNK, "\(name)")
            #expect(try fm.destinationOfSymbolicLink(atPath: link) == target, "\(name)")
        }
        #expect(!fm.fileExists(atPath: staged.path))
        for volume in [staging, target] {
            #expect(volume.mostOpenDirectories <= 2)
            #expect(volume.openDirectoryCount == 0)
        }
        #expect(trash.trashed.isEmpty)
    }

    @Test("across volumes, a symlink lands as itself, pointing where it did")
    func symlinkCopiesAcrossVolumes() throws {
        let staging = scratch.url.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let link = staging.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "nowhere")
        try setAttributes(link)
        let destination = try destinationFolder().appendingPathComponent("Link")

        try StagedItemLanding.land(
            link, at: destination, from: ClipboardArchiveLocalVolume(),
            to: InterposedArchiveVolume(failingRenamesWith: .improperLink), trash: { _ in })

        #expect(try linkStatus(destination.path).st_mode & S_IFMT == S_IFLNK)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == "nowhere")
        let status = try linkStatus(destination.path)
        #expect(sameInstant(status.st_mtimespec, Self.modification))
        var staged = stat()
        #expect(lstat(link.path, &staged) != 0)
    }

    /// exFAT and FAT refuse every flag but `UF_HIDDEN` with `EINVAL`.
    @Test(
        "across volumes, an attribute the destination cannot hold is left out of the copy, and the rest land",
        arguments: ArchiveAttributeKind.allCases)
    func unheldAttributeIsLeftOutOfTheCopy(kind: ArchiveAttributeKind) throws {
        let tree = try stagedTree("Tree")
        let file = tree.appendingPathComponent("sub/a.txt")
        try setAttributes(file, mode: 0o640, flags: UInt32(UF_HIDDEN))
        try setAttributes(tree, mode: 0o750, flags: UInt32(UF_HIDDEN))
        let destination = try destinationFolder().appendingPathComponent("Tree")
        let target = InterposedArchiveVolume(failingRenamesWith: .improperLink) { call throws(Errno) in
            if case .setAttribute(let attribute, _) = call, ArchiveAttributeKind(attribute) == kind {
                throw .invalidArgument
            }
        }

        try StagedItemLanding.land(
            tree, at: destination, from: ClipboardArchiveLocalVolume(), to: target, trash: { _ in })

        #expect(try Data(contentsOf: destination.appendingPathComponent("sub/a.txt")) == Data("one".utf8))
        for (url, mode) in [(destination.appendingPathComponent("sub/a.txt"), mode_t(0o640)), (destination, 0o750)] {
            let status = try linkStatus(url.path)
            let name = url.lastPathComponent
            #expect((status.st_mode & 0o7777 == mode) == (kind != .mode), "mode of \(name)")
            #expect((status.st_flags & UInt32(UF_HIDDEN) != 0) == (kind != .flags), "flags of \(name)")
            #expect(
                sameInstant(status.st_mtimespec, Self.modification) == (kind != .modification), "mtime of \(name)")
            #expect(
                sameInstant(status.st_birthtimespec, Self.creation) == (kind != .creation), "birth time of \(name)")
        }
        #expect(!FileManager.default.fileExists(atPath: tree.path))
    }

    @Test(
        "across volumes, or where a rename would replace, a file copies byte for byte with its attributes",
        arguments: [Errno.improperLink, .notSupported])
    func fileCopiesAcrossVolumes(renameFailure: Errno) throws {
        var generator = SystemRandomNumberGenerator()
        let bytes = Data(
            (0..<(ClipboardArchiveCodec.fileReadBlockSize + 3)).map { _ in
                UInt8.random(in: 0...255, using: &generator)
            })
        let representation = try staged("big.bin", bytes: bytes)
        let source = try #require(representation.fileURL)
        try setAttributes(source, mode: 0o604)
        let destination = try destinationFolder().appendingPathComponent("Big.bin")

        try StagedItemLanding.land(
            source, at: destination, from: ClipboardArchiveLocalVolume(),
            to: InterposedArchiveVolume(failingRenamesWith: renameFailure), trash: { _ in })

        #expect(try Data(contentsOf: destination) == bytes)
        try expectAttributes(destination, mode: 0o604)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test("across volumes, an existing item is never replaced, and the staged item stays", arguments: [false, true])
    func copyRefusesAnExistingItem(stagedIsFolder: Bool) throws {
        let source = stagedIsFolder ? try stagedTree("Item") : try #require(try staged("Item").fileURL)
        let destination = try destinationFolder().appendingPathComponent("Item")
        try Data("theirs".utf8).write(to: destination)
        let trash = TrashStandIn(scratch.url)

        let error = #expect(throws: POSIXError.self) {
            try StagedItemLanding.land(
                source, at: destination, from: ClipboardArchiveLocalVolume(),
                to: InterposedArchiveVolume(failingRenamesWith: .improperLink), trash: trash.trash)
        }
        #expect(error?.code == .EEXIST)
        #expect(try Data(contentsOf: destination) == Data("theirs".utf8))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(trash.trashed.isEmpty)
    }

    @Test(
        "across volumes, a create the destination refuses is thrown, and nothing goes to the Trash",
        arguments: [false, true])
    func refusedCreateIsThrown(stagedIsFolder: Bool) throws {
        let source = stagedIsFolder ? try stagedTree("Item") : try #require(try staged("Item").fileURL)
        let destination = try destinationFolder().appendingPathComponent("Item")
        let trash = TrashStandIn(scratch.url)
        let target = InterposedArchiveVolume(failingRenamesWith: .improperLink) { call throws(Errno) in
            switch call {
            case .makeDirectory, .createFile, .makeSymlink: throw .readOnlyFileSystem
            default: break
            }
        }

        let error = #expect(throws: POSIXError.self) {
            try StagedItemLanding.land(
                source, at: destination, from: ClipboardArchiveLocalVolume(), to: target, trash: trash.trash)
        }
        #expect(error?.code == .EROFS)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(trash.trashed.isEmpty)
    }

    @Test(
        "across volumes, a copy that fails part-way moves its output to the Trash and keeps the staged item",
        arguments: [Errno.noSpace, .ioError])
    func failedCopyGoesToTheTrash(failure: Errno) throws {
        let source = try stagedTree("Tree")
        let destination = try destinationFolder().appendingPathComponent("Tree")
        let trash = TrashStandIn(scratch.url)
        // A write the volume refuses, or an attribute it refuses for a reason
        // other than not holding it.
        let target = InterposedArchiveVolume(failingRenamesWith: .improperLink) { call throws(Errno) in
            switch (failure, call) {
            case (.noSpace, .write), (.ioError, .setAttribute(.mode(_), _)): throw failure
            default: break
            }
        }

        let error = #expect(throws: POSIXError.self) {
            try StagedItemLanding.land(
                source, at: destination, from: ClipboardArchiveLocalVolume(), to: target, trash: trash.trash)
        }
        #expect(error?.code.rawValue == failure.rawValue)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(trash.trashed.map(\.path) == [destination.path])
        #expect(try trash.contents() == ["Tree"])
        #expect(try Data(contentsOf: source.appendingPathComponent("sub/a.txt")) == Data("one".utf8))
    }

    @Test("across volumes, a failed copy the Trash refuses stays where it was made, and the copy's error is thrown")
    func failedCopyTheTrashRefusesStays() throws {
        let source = try stagedTree("Tree")
        let destination = try destinationFolder().appendingPathComponent("Tree")
        let trash = TrashStandIn(scratch.url, failingWith: CocoaError(.fileWriteNoPermission))

        let error = #expect(throws: POSIXError.self) {
            try StagedItemLanding.land(
                source, at: destination, from: ClipboardArchiveLocalVolume(),
                to: InterposedArchiveVolume(failingWritesWith: .noSpace, failingRenamesWith: .improperLink),
                trash: trash.trash)
        }
        #expect(error?.code == .ENOSPC)
        #expect(trash.trashed.map(\.path) == [destination.path])
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: source.appendingPathComponent("sub/a.txt")) == Data("one".utf8))
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
