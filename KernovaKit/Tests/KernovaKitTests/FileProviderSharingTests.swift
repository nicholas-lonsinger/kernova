import FileProvider
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import KernovaKit

@Suite("FileProviderItemIdentifier")
struct FileProviderItemIdentifierTests {
    @Test("make encodes salt, generation, and rep index into a decodable identifier")
    func makeRoundTrips() {
        for sessionSalt: UInt64 in [0, 7, .max] {
            for generation: UInt64 in [0, 1, 42, 65_535, 1 << 40] {
                for repIndex in [0, 1, 7, 65_535] {
                    let id = FileProviderItemIdentifier.make(
                        sessionSalt: sessionSalt, generation: generation, repIndex: repIndex)
                    let decoded = FileProviderItemIdentifier.decode(id)
                    #expect(decoded?.sessionSalt == sessionSalt)
                    #expect(decoded?.generation == generation)
                    #expect(decoded?.repIndex == repIndex)
                }
            }
        }
    }

    @Test("the same (generation, repIndex) under different session salts yields distinct identifiers")
    func saltDisambiguatesSessions() {
        // The collision #541 fixes: generation counters restart every owner
        // session, so cross-session uniqueness comes from the salt alone.
        let a = FileProviderItemIdentifier.make(sessionSalt: 1, generation: 1, repIndex: 0)
        let b = FileProviderItemIdentifier.make(sessionSalt: 2, generation: 1, repIndex: 0)
        #expect(a != b)
    }

    @Test("decode rejects reserved container identifiers and garbage")
    func decodeRejectsNonOurs() {
        #expect(FileProviderItemIdentifier.decode("NSFileProviderRootContainerItemIdentifier") == nil)
        #expect(FileProviderItemIdentifier.decode("NSFileProviderWorkingSetContainerItemIdentifier") == nil)
        #expect(FileProviderItemIdentifier.decode("") == nil)
        #expect(FileProviderItemIdentifier.decode("clipfile") == nil)
        #expect(FileProviderItemIdentifier.decode("clipfile.1") == nil)
        // The pre-salt three-part form (#541) — no legacy decode.
        #expect(FileProviderItemIdentifier.decode("clipfile.1.2") == nil)
        #expect(FileProviderItemIdentifier.decode("clipfile.1.2.3.4") == nil)
        #expect(FileProviderItemIdentifier.decode("other.1.2.3") == nil)
        // Non-numeric / negative components.
        #expect(FileProviderItemIdentifier.decode("clipfile.x.0.0") == nil)
        #expect(FileProviderItemIdentifier.decode("clipfile.1.x.0") == nil)
        #expect(FileProviderItemIdentifier.decode("clipfile.1.1.-1") == nil)
    }

    @Test("identifiers avoid the framework-reserved `/` and `:` characters")
    func identifierAvoidsReservedCharacters() {
        let id = FileProviderItemIdentifier.make(sessionSalt: 11, generation: 5, repIndex: 3)
        #expect(!id.contains("/"))
        #expect(!id.contains(":"))
    }
}

@Suite("FileProviderManifest")
struct FileProviderManifestTests {
    private func makeManifest() -> FileProviderManifest {
        FileProviderManifest(
            generation: 9,
            items: [
                .init(
                    sessionSalt: 4, generation: 9, repIndex: 0, filename: "report.pdf",
                    byteCount: 1_234, uti: "com.adobe.pdf")
            ])
    }

    @Test("encodes and decodes losslessly")
    func codableRoundTrips() throws {
        let manifest = makeManifest()
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(FileProviderManifest.self, from: data)
        #expect(decoded == manifest)
    }

    @Test("item(for:) resolves the matching identifier")
    func itemLookupResolves() {
        let manifest = makeManifest()
        let id = FileProviderItemIdentifier.make(sessionSalt: 4, generation: 9, repIndex: 0)
        let item = manifest.item(for: id)
        #expect(item?.filename == "report.pdf")
        #expect(item?.byteCount == 1_234)
        #expect(item?.uti == "com.adobe.pdf")
    }

    @Test("item(for:) returns nil for a stale generation or unknown rep")
    func itemLookupRejectsStale() {
        let manifest = makeManifest()
        // Same rep, different (superseded) generation.
        #expect(
            manifest.item(for: FileProviderItemIdentifier.make(sessionSalt: 4, generation: 8, repIndex: 0))
                == nil)
        // Unknown rep index in the current generation.
        #expect(
            manifest.item(for: FileProviderItemIdentifier.make(sessionSalt: 4, generation: 9, repIndex: 1))
                == nil)
        // Same (generation, repIndex) from a different session (#541).
        #expect(
            manifest.item(for: FileProviderItemIdentifier.make(sessionSalt: 5, generation: 9, repIndex: 0))
                == nil)
        // Not one of ours.
        #expect(manifest.item(for: "garbage") == nil)
    }

    @Test("an item's itemIdentifier matches the shared encoder")
    func itemIdentifierMatchesEncoder() {
        let item = FileProviderManifest.Item(
            sessionSalt: 6, generation: 3, repIndex: 2, filename: "a.bin", byteCount: 1,
            uti: "public.data")
        #expect(
            item.itemIdentifier
                == FileProviderItemIdentifier.make(sessionSalt: 6, generation: 3, repIndex: 2))
    }

    @Test("the empty manifest carries no items and the no-offer sentinel generation")
    func emptyManifest() {
        #expect(FileProviderManifest.empty.items.isEmpty)
        #expect(FileProviderManifest.empty.folders.isEmpty)
        #expect(FileProviderManifest.empty.generation == 0)
    }
}

@Suite("FileProviderManifest folder tree")
struct FileProviderManifestFolderTests {
    private func makeManifest() -> FileProviderManifest {
        // A directory rep (repIndex 0): root folder with a top-level file, a
        // subdirectory, and a file nested inside that subdirectory.
        let file = FileProviderManifest.FolderRep.Node(
            childSeq: 1, parentChildSeq: 0, kind: .file, filename: "top.txt",
            relativePath: "top.txt", byteCount: 4, uti: "public.plain-text")
        let sub = FileProviderManifest.FolderRep.Node(
            childSeq: 2, parentChildSeq: 0, kind: .directory, filename: "sub",
            relativePath: "sub", byteCount: 0, uti: "public.folder")
        let nested = FileProviderManifest.FolderRep.Node(
            childSeq: 3, parentChildSeq: 2, kind: .file, filename: "b.bin", relativePath: "sub/b.bin",
            byteCount: 8, uti: "public.data")
        let folder = FileProviderManifest.FolderRep(
            sessionSalt: 4, generation: 9, repIndex: 0, filename: "MyFolder", uti: "public.folder",
            isPackage: false, byteCount: 12, mtimeMs: 0, nodes: [file, sub, nested])
        // Plus a flat single-file rep (repIndex 1) to prove the two coexist.
        let flat = FileProviderManifest.Item(
            sessionSalt: 4, generation: 9, repIndex: 1, filename: "report.pdf", byteCount: 100,
            uti: "com.adobe.pdf")
        return FileProviderManifest(generation: 9, items: [flat], folders: [folder])
    }

    @Test("codable round-trips with folders and their nodes")
    func codableRoundTrips() throws {
        let manifest = makeManifest()
        let decoded = try JSONDecoder().decode(
            FileProviderManifest.self, from: JSONEncoder().encode(manifest))
        #expect(decoded == manifest)
    }

    @Test("resolve maps flat files, folder roots, and tree nodes")
    func resolveMapsEveryKind() throws {
        let manifest = makeManifest()
        let folder = manifest.folders[0]
        // Flat file.
        if case .flatFile(let item)? = manifest.resolve(manifest.items[0].itemIdentifier) {
            #expect(item.filename == "report.pdf")
        } else {
            Issue.record("flat file did not resolve")
        }
        // Folder root.
        if case .folderRoot(let root)? = manifest.resolve(folder.rootIdentifier) {
            #expect(root.filename == "MyFolder")
        } else {
            Issue.record("folder root did not resolve")
        }
        // Nested node.
        let nested = folder.nodes.first { $0.relativePath == "sub/b.bin" }!
        if case .node(_, let node)? = manifest.resolve(folder.identifier(for: nested)) {
            #expect(node.relativePath == "sub/b.bin")
        } else {
            Issue.record("nested node did not resolve")
        }
        // A stale generation / unknown identifier resolves to nil.
        #expect(
            manifest.resolve(
                FileProviderItemIdentifier.makeNode(
                    sessionSalt: 4, generation: 8, repIndex: 0, childSeq: 0)) == nil)
        #expect(manifest.resolve("garbage") == nil)
    }

    @Test("rootEntries lists flat files plus folder roots; children serves by container")
    func enumerationEntries() throws {
        let manifest = makeManifest()
        let folder = manifest.folders[0]
        let (files, folderRoots) = manifest.rootEntries()
        #expect(files.map(\.filename) == ["report.pdf"])
        #expect(folderRoots.map(\.filename) == ["MyFolder"])

        // The folder root's direct children: the top-level file and the subdir.
        let rootChildren = try #require(manifest.children(ofContainer: folder.rootIdentifier))
        #expect(Set(rootChildren.map { $0.1.relativePath }) == ["top.txt", "sub"])

        // The subdirectory's children: the nested file.
        let sub = folder.nodes.first { $0.relativePath == "sub" }!
        let subChildren = try #require(
            manifest.children(ofContainer: folder.identifier(for: sub)))
        #expect(subChildren.map { $0.1.relativePath } == ["sub/b.bin"])

        // A file node is not a container.
        let file = folder.nodes.first { $0.relativePath == "top.txt" }!
        #expect(manifest.children(ofContainer: folder.identifier(for: file)) == nil)
    }
}

@Suite("ClipboardTreeItem fidelity")
struct ClipboardTreeItemFidelityTests {
    private func manifest(nodes: [FileProviderManifest.FolderRep.Node], rootUTI: String = "public.folder")
        -> FileProviderManifest
    {
        FileProviderManifest(
            generation: 5, items: [],
            folders: [
                FileProviderManifest.FolderRep(
                    sessionSalt: 2, generation: 5, repIndex: 0, filename: "Root", uti: rootUTI,
                    isPackage: rootUTI != "public.folder", byteCount: 0, mtimeMs: 0, nodes: nodes)
            ])
    }

    private func treeItem(
        _ manifest: FileProviderManifest, _ identifier: String
    ) throws -> ClipboardTreeItem {
        try #require(FileProviderExtension.item(for: identifier, in: manifest) as? ClipboardTreeItem)
    }

    @Test("an executable file node preserves the executable bit via fileSystemFlags")
    func executableBitPreserved() throws {
        let node = FileProviderManifest.FolderRep.Node(
            childSeq: 1, parentChildSeq: 0, kind: .file, filename: "run", relativePath: "run",
            byteCount: 8, uti: "public.data", posixPermissions: 0o755)
        let m = manifest(nodes: [node])
        let item = try treeItem(m, m.folders[0].identifier(for: node))
        #expect(item.fileSystemFlags.contains(.userExecutable))
        #expect(item.documentSize?.intValue == 8)
    }

    @Test("a non-executable file node does not set the executable bit")
    func nonExecutableBit() throws {
        let node = FileProviderManifest.FolderRep.Node(
            childSeq: 1, parentChildSeq: 0, kind: .file, filename: "doc.txt",
            relativePath: "doc.txt", byteCount: 3, uti: "public.plain-text", posixPermissions: 0o644)
        let m = manifest(nodes: [node])
        let item = try treeItem(m, m.folders[0].identifier(for: node))
        #expect(!item.fileSystemFlags.contains(.userExecutable))
    }

    @Test("a symlink node carries its target path and the symbolic-link content type")
    func symlinkFidelity() throws {
        let node = FileProviderManifest.FolderRep.Node(
            childSeq: 1, parentChildSeq: 0, kind: .symlink, filename: "link", relativePath: "link",
            byteCount: 0, uti: UTType.symbolicLink.identifier, symlinkTarget: "../target")
        let m = manifest(nodes: [node])
        let item = try treeItem(m, m.folders[0].identifier(for: node))
        #expect(item.symlinkTargetPath == "../target")
        #expect(item.contentType == .symbolicLink)
    }

    @Test("a package folder root carries a package content type")
    func packageContentType() throws {
        let appType = UTType(filenameExtension: "app")!
        let m = manifest(nodes: [], rootUTI: appType.identifier)
        let item = try treeItem(m, m.folders[0].rootIdentifier)
        // The root carries the bundle content type, so a pasted .app opens as a
        // package rather than a plain folder.
        #expect(item.contentType == appType)
        #expect(item.contentType != .folder)
    }

    @Test("a directory node reports its direct child count and a folder content type")
    func directoryNode() throws {
        let dir = FileProviderManifest.FolderRep.Node(
            childSeq: 1, parentChildSeq: 0, kind: .directory, filename: "sub", relativePath: "sub",
            byteCount: 0, uti: "public.folder")
        let child = FileProviderManifest.FolderRep.Node(
            childSeq: 2, parentChildSeq: 1, kind: .file, filename: "x.txt", relativePath: "sub/x.txt",
            byteCount: 1, uti: "public.plain-text")
        let m = manifest(nodes: [dir, child])
        let item = try treeItem(m, m.folders[0].identifier(for: dir))
        #expect(item.contentType == .folder)
        #expect(item.childItemCount?.intValue == 1)
    }
}

@Suite("FileProviderTreeNodeIdentifier")
struct FileProviderTreeNodeIdentifierTests {
    @Test("makeNode round-trips salt/generation/repIndex/childSeq")
    func nodeRoundTrips() {
        for childSeq: UInt32 in [0, 1, 100_000, .max] {
            let id = FileProviderItemIdentifier.makeNode(
                sessionSalt: 7, generation: 3, repIndex: 2, childSeq: childSeq)
            let decoded = FileProviderItemIdentifier.decodeNode(id)
            #expect(decoded?.sessionSalt == 7)
            #expect(decoded?.generation == 3)
            #expect(decoded?.repIndex == 2)
            #expect(decoded?.childSeq == childSeq)
            // Never mistaken for a flat identifier, and vice versa.
            #expect(FileProviderItemIdentifier.decode(id) == nil)
        }
    }

    @Test("decodeNode rejects flat identifiers and garbage")
    func decodeNodeRejects() {
        #expect(
            FileProviderItemIdentifier.decodeNode(
                FileProviderItemIdentifier.make(sessionSalt: 1, generation: 1, repIndex: 0)) == nil)
        #expect(FileProviderItemIdentifier.decodeNode("clipnode.1.2.3") == nil)
        #expect(FileProviderItemIdentifier.decodeNode("clipnode.1.2.-1.0") == nil)
        #expect(FileProviderItemIdentifier.decodeNode("garbage") == nil)
    }
}
