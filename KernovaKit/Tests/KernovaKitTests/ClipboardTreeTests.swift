import Foundation
import Testing
import UniformTypeIdentifiers

@testable import KernovaKit

// Folder placeholder-tree unit coverage (folder D1b, #422): the child
// transfer-id scheme, proto round-trips, directory-tree walking/serialization,
// and the listing → hierarchical-manifest bridge.

@Suite("ClipboardTransferID child scheme")
struct ClipboardTransferIDTests {
    @Test("legacy ids are unchanged and decode their generation/direction")
    func legacyRoundTrips() {
        for generation: UInt64 in [1, 42, 65_535, 1 << 30] {
            for repIndex in [0, 1, 0xFFFF] {
                let guestID = ClipboardTransferID.make(
                    generation: generation, repIndex: repIndex, hostMinted: false)
                let hostID = ClipboardTransferID.make(
                    generation: generation, repIndex: repIndex, hostMinted: true)
                #expect(!ClipboardTransferID.isChild(guestID))
                #expect(!ClipboardTransferID.isChild(hostID))
                #expect(!ClipboardTransferID.hostReceives(guestID))
                #expect(ClipboardTransferID.hostReceives(hostID))
                #expect(ClipboardTransferID.generation(of: guestID) == generation)
                #expect(ClipboardTransferID.generation(of: hostID) == generation)
                // The classic layout — bit 62 clear, rep index in the low 16 bits.
                #expect(guestID & ClipboardTransferID.childTransferBit == 0)
                #expect(Int(guestID & 0xFFFF) == repIndex)
            }
        }
    }

    @Test("child ids encode generation, rep, and child seq, and tag direction + child bit")
    func childRoundTrips() {
        for generation: UInt64 in [1, 42, 4096, (1 << 24) - 1] {
            for repIndex in [0, 3, 0xFFFF] {
                for childSeq: UInt32 in [0, 1, 100_000, (1 << 22) - 1] {
                    let guestID = ClipboardTransferID.makeChild(
                        generation: generation, repIndex: repIndex, childSeq: childSeq,
                        hostMinted: false)
                    let hostID = ClipboardTransferID.makeChild(
                        generation: generation, repIndex: repIndex, childSeq: childSeq,
                        hostMinted: true)
                    #expect(ClipboardTransferID.isChild(guestID))
                    #expect(ClipboardTransferID.isChild(hostID))
                    #expect(!ClipboardTransferID.hostReceives(guestID))
                    #expect(ClipboardTransferID.hostReceives(hostID))
                    #expect(ClipboardTransferID.generation(of: guestID) == generation)
                    #expect(ClipboardTransferID.generation(of: hostID) == generation)
                    #expect(ClipboardTransferID.childSeq(of: guestID) == childSeq)
                    #expect(ClipboardTransferID.childSeq(of: hostID) == childSeq)
                }
            }
        }
    }

    @Test("a child id never collides with a legacy id at the same (generation, repIndex)")
    func childAndLegacyDisjoint() {
        let legacy = ClipboardTransferID.make(generation: 5, repIndex: 2, hostMinted: false)
        let listing = ClipboardTransferID.makeChild(
            generation: 5, repIndex: 2, childSeq: 0, hostMinted: false)
        let child = ClipboardTransferID.makeChild(
            generation: 5, repIndex: 2, childSeq: 1, hostMinted: false)
        #expect(legacy != listing)
        #expect(legacy != child)
        #expect(listing != child)
    }

    @Test("determinism: re-deriving a child id from the same key yields the same value")
    func childDeterminism() {
        let first = ClipboardTransferID.makeChild(
            generation: 9, repIndex: 4, childSeq: 77, hostMinted: true)
        let second = ClipboardTransferID.makeChild(
            generation: 9, repIndex: 4, childSeq: 77, hostMinted: true)
        #expect(first == second)
    }
}

@Suite("ClipboardTreeFetch/Listing proto")
struct ClipboardTreeProtoTests {
    @Test("ClipboardTreeFetch round-trips through protobuf")
    func fetchRoundTrips() throws {
        var fetch = Kernova_V1_ClipboardTreeFetch()
        fetch.generation = 7
        fetch.transferID = ClipboardTransferID.makeChild(
            generation: 7, repIndex: 1, childSeq: 3, hostMinted: false)
        fetch.repIndex = 1
        fetch.relativePath = "sub/dir/file.txt"
        fetch.maxAcceptByteCount = 1 << 40
        let decoded = try Kernova_V1_ClipboardTreeFetch(serializedBytes: try fetch.serializedData())
        #expect(decoded == fetch)
    }

    @Test("a listing with file/dir/symlink entries round-trips through serialize/deserialize")
    func listingRoundTrips() throws {
        var file = Kernova_V1_ClipboardTreeEntry()
        file.relativePath = "a.txt"
        file.kind = .file
        file.byteCount = 12
        file.posixPermissions = 0o644
        file.mtimeMs = 1_700_000_000_000
        file.childSeq = 1
        var dir = Kernova_V1_ClipboardTreeEntry()
        dir.relativePath = "sub"
        dir.kind = .directory
        dir.isPackage = false
        dir.childSeq = 2
        var link = Kernova_V1_ClipboardTreeEntry()
        link.relativePath = "link"
        link.kind = .symlink
        link.symlinkTarget = "a.txt"
        link.childSeq = 3
        let entries = [file, dir, link]
        let restored = try ClipboardDirectoryTree.deserializeListing(
            ClipboardDirectoryTree.serializeListing(entries))
        #expect(restored == entries)
    }
}

@Suite("ClipboardDirectoryTree walk")
struct ClipboardDirectoryTreeTests {
    /// Builds a temp tree with a plain file, an executable, an empty dir, a
    /// nested file, and a symlink; returns the root (caller sweeps it).
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("a.txt"))
        let script = root.appendingPathComponent("run.sh")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try fm.createDirectory(
            at: root.appendingPathComponent("empty", isDirectory: true),
            withIntermediateDirectories: true)
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: sub.appendingPathComponent("b.txt"))
        // A relative symlink (the realistic in-tree case), so its raw target
        // round-trips as "a.txt" rather than an absolute path.
        try fm.createSymbolicLink(
            atPath: root.appendingPathComponent("link").path, withDestinationPath: "a.txt")
        return root
    }

    @Test("enumerateTree records files, an executable bit, an empty dir, nesting, and a symlink")
    func enumerateCapturesFidelity() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try ClipboardDirectoryTree.enumerateTree(at: root)
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0) })

        #expect(byPath["a.txt"]?.kind == .file)
        #expect(byPath["a.txt"]?.byteCount == 5)
        #expect(byPath["run.sh"]?.kind == .file)
        // Executable bit preserved (the .app-signature acid test in miniature).
        #expect((byPath["run.sh"]?.posixPermissions ?? 0) & 0o111 != 0)
        #expect(byPath["empty"]?.kind == .directory)
        #expect(byPath["sub"]?.kind == .directory)
        #expect(byPath["sub/b.txt"]?.kind == .file)
        #expect(byPath["sub/b.txt"]?.byteCount == 6)
        #expect(byPath["link"]?.kind == .symlink)
        #expect(byPath["link"]?.symlinkTarget == "a.txt")
        // Every child seq is unique and 1-based.
        let seqs = entries.map(\.childSeq)
        #expect(Set(seqs).count == seqs.count)
        #expect(seqs.allSatisfy { $0 >= 1 })
    }

    @Test("estimatedByteCount sums regular-file sizes only")
    func estimateSumsFiles() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        // a.txt (5) + run.sh (10) + sub/b.txt (6) = 21; dirs/symlinks contribute 0.
        #expect(ClipboardDirectoryTree.estimatedByteCount(at: root) == 21)
    }

    @Test("resolveChildFile confines resolution and rejects non-regular / escaping paths")
    func resolveConfines() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ClipboardDirectoryTree.resolveChildFile(root: root, relativePath: "a.txt") != nil)
        #expect(
            ClipboardDirectoryTree.resolveChildFile(root: root, relativePath: "sub/b.txt") != nil)
        // Escapes and unsafe forms.
        #expect(ClipboardDirectoryTree.resolveChildFile(root: root, relativePath: "../secret") == nil)
        #expect(ClipboardDirectoryTree.resolveChildFile(root: root, relativePath: "/etc/hosts") == nil)
        #expect(ClipboardDirectoryTree.resolveChildFile(root: root, relativePath: "") == nil)
        // A directory, a symlink leaf, and a missing file are not fetchable.
        #expect(ClipboardDirectoryTree.resolveChildFile(root: root, relativePath: "empty") == nil)
        #expect(ClipboardDirectoryTree.resolveChildFile(root: root, relativePath: "link") == nil)
        #expect(ClipboardDirectoryTree.resolveChildFile(root: root, relativePath: "nope.txt") == nil)
    }

    @Test("makeFolderRep derives parents by relative-path prefix and content UTIs")
    func makeFolderRepBuildsHierarchy() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try ClipboardDirectoryTree.enumerateTree(at: root)
        let folder = ClipboardDirectoryTree.makeFolderRep(
            sessionSalt: 3, generation: 9, repIndex: 0, filename: "Folder", isPackage: false,
            estimatedByteCount: 21, rootMtimeMs: 0, entries: entries)
        let bySeq = Dictionary(uniqueKeysWithValues: folder.nodes.map { ($0.relativePath, $0) })
        let subSeq = try #require(bySeq["sub"]).childSeq
        // A root-level file's parent is the folder root (parentChildSeq 0).
        #expect(bySeq["a.txt"]?.parentChildSeq == 0)
        // A nested file's parent is its directory node.
        #expect(bySeq["sub/b.txt"]?.parentChildSeq == subSeq)
        // Content UTIs derived from the name/kind.
        #expect(bySeq["a.txt"]?.uti == UTType.plainText.identifier)
        #expect(bySeq["link"]?.uti == UTType.symbolicLink.identifier)
        #expect(bySeq["sub"]?.uti == ClipboardDirectoryTree.folderUTI)
        #expect(folder.rootIdentifier.hasPrefix("clipnode."))
    }

    @Test("a package folder root gets its bundle content UTI")
    func packageRootUTI() {
        let folder = ClipboardDirectoryTree.makeFolderRep(
            sessionSalt: 1, generation: 1, repIndex: 0, filename: "My.app", isPackage: true,
            estimatedByteCount: 0, rootMtimeMs: 0, entries: [])
        #expect(folder.uti == UTType(filenameExtension: "app")?.identifier)
    }
}
