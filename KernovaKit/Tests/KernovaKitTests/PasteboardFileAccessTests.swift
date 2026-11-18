import AppKit
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// The grants reading a pasteboard's file URLs takes, held by what the read offers and given back once nothing does,
/// over a fake pasteboard whose sandbox counts them as a Mac does.
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

    @Test(
        "An offer, a drop's or a copy's, holds each file's grant while it lives, and gives each back once as it goes",
        arguments: [true, false])
    func offerHoldsItsGrants(drop: Bool) async throws {
        let files = [try file("a.txt"), try file("b.txt")]
        let pasteboard = FakePasteboard()
        pasteboard.setFiles(files)
        let sandbox = pasteboard.sandbox

        var source = await offer(pasteboard, drop: drop)
        withExtendedLifetime(source) {
            #expect(source?.items.count == 2)
            #expect(files.map(sandbox.grants(of:)) == [1, 1])
        }
        source = nil

        try await sandbox.changed.wait { files.allSatisfy { sandbox.grants(of: $0) == 0 } }
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

    @Test("Two reads of one copy share its grants: they are given back once, when the second read's offer goes too")
    func readsOfOneCopyShareGrants() async throws {
        let copied = try file("copied.txt")
        let pasteboard = FakePasteboard()
        pasteboard.setFiles([copied])
        let sandbox = pasteboard.sandbox

        var first = await offer(pasteboard, drop: false)
        var second = await offer(pasteboard, drop: false)
        #expect(first != nil)
        first = nil

        withExtendedLifetime(second) {
            #expect(second != nil)
            #expect(sandbox.grants(of: copied) == 1)
        }
        second = nil
        try await sandbox.changed.wait { sandbox.grants(of: copied) == 0 }
        #expect(sandbox.unheldGiveBacks.isEmpty)
    }

    @Test("A copy read again once its grants were given back takes none, so its offer holds none and gives none back")
    func rereadAfterGiveBackGivesNoneBack() async throws {
        let copied = try file("copied.txt")
        let pasteboard = FakePasteboard()
        pasteboard.setFiles([copied])
        let sandbox = pasteboard.sandbox
        var source = await offer(pasteboard, drop: false)
        #expect(source?.fileAccess != nil)
        source = nil
        try await sandbox.changed.wait { sandbox.grants(of: copied) == 0 }

        source = await offer(pasteboard, drop: false)
        #expect(source != nil)
        #expect(source?.fileAccess == nil)
        source = nil

        #expect(sandbox.grants(of: copied) == 0)
        #expect(sandbox.unheldGiveBacks.isEmpty)
    }
}
