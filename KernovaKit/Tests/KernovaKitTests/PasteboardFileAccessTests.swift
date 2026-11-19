import AppKit
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// The grants reading a pasteboard's file URLs takes and the bookmarks a copy's read makes, held by what the read
/// offers, over a fake pasteboard whose sandbox counts grants and follows bookmarks as a Mac does.
@Suite("PasteboardFileAccess", .caseScoped)
@MainActor
struct PasteboardFileAccessTests {
    private let scratch = TestScratchDirectory(prefix: "pasteboard-file-access")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    private func file(_ name: String) throws -> URL {
        let url = scratch.url.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }

    /// The source of the offer reading `pasteboard` makes as `drop` or as a copy says, or nil, recorded, when it
    /// makes none.
    private func offer(_ pasteboard: FakePasteboard, drop: Bool) async -> ClipboardOfferSource? {
        let outcome =
            drop
            ? await ClipboardPasteboardReader.readDropOffer(from: pasteboard, promises: [], sizeOf: nil)
            : await ClipboardPasteboardReader.readOffer(from: pasteboard, publisher: .elsewhere(), sizeOf: nil)
        guard case .offer(let source, lost: 0) = outcome else {
            Issue.record("expected an offer leaving nothing out, got \(outcome)")
            return nil
        }
        return source
    }

    private struct NotAFile: Error {
        let served: ClipboardServedRepresentation
    }

    /// The FILE `source` serves of its first item, which the caller holds its grant while it has.
    private func servedFile(of source: ClipboardOfferSource?) async throws -> (url: URL, served: ClipboardServed) {
        let served = try await #require(source).serve(item: 0, representation: 0)
        guard case .file(let url) = served.representation else { throw NotAFile(served: served.representation) }
        return (url, served)
    }

    @Test("A drop's offer holds each file's grant while it lives, and gives each back once as it goes")
    func dropOfferHoldsItsGrants() async throws {
        let files = [try file("a.txt"), try file("b.txt")]
        let pasteboard = FakePasteboard()
        pasteboard.setFiles(files)
        let sandbox = pasteboard.sandbox

        var source = await offer(pasteboard, drop: true)
        withExtendedLifetime(source) {
            #expect(source?.items.count == 2)
            #expect(files.map(sandbox.grants(of:)) == [1, 1])
        }
        source = nil

        try await sandbox.changed.wait { files.allSatisfy { sandbox.grants(of: $0) == 0 } }
        #expect(sandbox.unheldGiveBacks.isEmpty)
    }

    @Test("A copy's offer holds no grant while it stands: its read gives each back once it has bookmarked the file")
    func copyOfferHoldsNoGrant() async throws {
        let files = [try file("a.txt"), try file("b.txt")]
        let pasteboard = FakePasteboard()
        pasteboard.setFiles(files)
        let sandbox = pasteboard.sandbox

        let source = await offer(pasteboard, drop: false)

        withExtendedLifetime(source) {
            #expect(source?.items.count == 2)
            #expect(files.map(sandbox.grants(of:)) == [0, 0])
        }
        #expect(sandbox.bookmarksAsked == 2)
        #expect(sandbox.unheldGiveBacks.isEmpty)
    }

    @Test("A drop of files none of which this process can open gives their grants back as the read ends")
    func unopenableDropGivesBackAtOnce() async throws {
        let locked = try file("locked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let pasteboard = FakePasteboard()
        pasteboard.setFiles([locked])

        let outcome = await ClipboardPasteboardReader.readDropOffer(from: pasteboard, promises: [], sizeOf: nil)

        guard case .nothingOfferable(lost: 1) = outcome else {
            Issue.record("expected nothing offerable, one item left out, got \(outcome)")
            return
        }
        let sandbox = pasteboard.sandbox
        try await sandbox.changed.wait { sandbox.grants(of: locked) == 0 }
        #expect(sandbox.unheldGiveBacks.isEmpty)
    }

    @Test("A pull of a copied file is served under a grant of its own, held while the pull holds it")
    func copiedFileIsServedUnderItsOwnGrant() async throws {
        let copied = try file("copied.txt")
        let pasteboard = FakePasteboard()
        pasteboard.setFiles([copied])
        let sandbox = pasteboard.sandbox
        let source = await offer(pasteboard, drop: false)

        var pulled: (url: URL, served: ClipboardServed)? = try await servedFile(of: source)
        #expect(pulled?.url.resolvingSymlinksInPath().path == copied.resolvingSymlinksInPath().path)
        #expect(sandbox.grants(of: copied) == 1)
        pulled = nil

        #expect(sandbox.grants(of: copied) == 0)
        #expect(sandbox.unheldGiveBacks.isEmpty)
    }

    @Test("A copied file moved after the copy is served from where it is now")
    func movedCopiedFileIsServedWhereItIs() async throws {
        let copied = try file("copied.txt")
        let pasteboard = FakePasteboard()
        pasteboard.setFiles([copied])
        let source = await offer(pasteboard, drop: false)
        let moved = scratch.url.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: copied, to: moved.appendingPathComponent("renamed.txt"))

        let pulled = try await servedFile(of: source)

        #expect(pulled.url.lastPathComponent == "renamed.txt")
        #expect(try Data(contentsOf: pulled.url) == Data("copied.txt".utf8))
        #expect(pasteboard.sandbox.grants(of: pulled.url) == 1)
    }

    @Test("Two ends reading one copy each serve its file, the second through the bookmark the first made")
    func twoReadsOfOneCopyBothServe() async throws {
        let copied = try file("copied.txt")
        let pasteboard = FakePasteboard()
        pasteboard.setFiles([copied])
        let sandbox = pasteboard.sandbox

        let first = await offer(pasteboard, drop: false)
        let second = await offer(pasteboard, drop: false)
        let pulls = [try await servedFile(of: first), try await servedFile(of: second)]

        let path = copied.resolvingSymlinksInPath().path
        #expect(pulls.map { $0.url.resolvingSymlinksInPath().path } == [path, path])
        #expect(sandbox.grants(of: copied) == 2)
        #expect(sandbox.bookmarksAsked == 1)
    }

    @Test("A copy read again after its first offer went serves its file through the bookmark the first read made")
    func rereadOfACopyServes() async throws {
        let copied = try file("copied.txt")
        let pasteboard = FakePasteboard()
        pasteboard.setFiles([copied])
        var source = await offer(pasteboard, drop: false)
        #expect(source != nil)
        source = nil

        source = await offer(pasteboard, drop: false)
        let pulled = try await servedFile(of: source)

        #expect(pulled.url.resolvingSymlinksInPath().path == copied.resolvingSymlinksInPath().path)
        #expect(pasteboard.sandbox.grants(of: copied) == 1)
    }

    @Test("A pasteboard read again once its grants were given back takes none, so holds none and gives none back")
    func rereadAfterGiveBackGivesNoneBack() async throws {
        let copied = try file("copied.txt")
        let pasteboard = FakePasteboard()
        pasteboard.setFiles([copied])
        let sandbox = pasteboard.sandbox
        var source = await offer(pasteboard, drop: true)
        #expect(source?.fileAccess != nil)
        source = nil
        try await sandbox.changed.wait { sandbox.grants(of: copied) == 0 }

        _ = await ClipboardPasteboardReader.readOffer(from: pasteboard, publisher: .elsewhere(), sizeOf: nil)
        let reread = PasteboardFileAccess.readFileURLs(from: pasteboard)

        #expect(reread.urls == [copied])
        #expect(!reread.access.holdsGrants)
        #expect(sandbox.unheldGiveBacks.isEmpty)
    }

    @Test("A read of a drop's file URLs holds their grants while its access lives, and gives each back once after")
    func fileURLReadHoldsItsGrants() async throws {
        let files = [try file("a.txt"), try file("b.txt")]
        let pasteboard = FakePasteboard()
        pasteboard.setFiles(files)
        let sandbox = pasteboard.sandbox

        var read: (urls: [URL], access: PasteboardFileAccess)? = PasteboardFileAccess.readFileURLs(from: pasteboard)
        withExtendedLifetime(read) {
            #expect(read?.urls == files)
            #expect(files.map(sandbox.grants(of:)) == [1, 1])
        }
        read = nil

        try await sandbox.changed.wait { files.allSatisfy { sandbox.grants(of: $0) == 0 } }
        #expect(sandbox.unheldGiveBacks.isEmpty)
    }
}
