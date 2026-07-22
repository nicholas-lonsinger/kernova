import Foundation
import Testing

@testable import KernovaKit

/// Unit tests for `FileProviderOfferURLIndex` (#634).
///
/// The index is what lets an in-flight relay pull name the placeholder it is
/// materializing, so the owner can publish a progress Finder's copy dialog
/// subscribes to by file URL. Its whole contract is the resolution rule — root
/// placeholder for a flat rep, `<folder root>/<relativePath>` for a tree child,
/// and `nil` for anything that isn't the current offer — so it is exercised
/// directly here, with no domain host or relay in the picture.
@Suite("FileProviderOfferURLIndex")
struct FileProviderOfferURLIndexTests {
    private let root = URL(fileURLWithPath: "/Users/test/Library/CloudStorage/Kernova-clipboard")

    @Test("a flat rep resolves to the root placeholder's URL")
    func flatRepResolvesToRootPlaceholder() {
        let index = FileProviderOfferURLIndex()
        index.update(
            generation: 7,
            urls: [
                0: root.appendingPathComponent("report.pdf"),
                1: root.appendingPathComponent("report (2).pdf"),
            ])

        #expect(
            index.url(generation: 7, repIndex: 0, relativePath: nil)
                == root.appendingPathComponent("report.pdf"))
        // The de-duplicated name the publish path minted, not the raw filename —
        // the point of caching the publish path's own output.
        #expect(
            index.url(generation: 7, repIndex: 1, relativePath: nil)
                == root.appendingPathComponent("report (2).pdf"))
        #expect(index.url(generation: 7, repIndex: 2, relativePath: nil) == nil)
    }

    @Test("a tree child appends its relative path one component at a time")
    func childAppendsRelativePathComponentwise() {
        let index = FileProviderOfferURLIndex()
        index.update(generation: 3, urls: [0: root.appendingPathComponent("folder")])

        let resolved = index.url(generation: 3, repIndex: 0, relativePath: "sub/file.txt")
        #expect(resolved == root.appendingPathComponent("folder/sub/file.txt"))
        // Component-wise appending, not one `appendingPathComponent("sub/file.txt")`
        // call: the separator has to be a real path boundary.
        #expect(resolved?.lastPathComponent == "file.txt")
        #expect(resolved?.deletingLastPathComponent().lastPathComponent == "sub")
    }

    @Test("empty relative-path components are dropped")
    func emptyRelativePathComponentsDropped() {
        let index = FileProviderOfferURLIndex()
        index.update(generation: 3, urls: [0: root.appendingPathComponent("folder")])

        #expect(
            index.url(generation: 3, repIndex: 0, relativePath: "/sub//file.txt")
                == root.appendingPathComponent("folder/sub/file.txt"))
        // A degenerate empty path resolves to the folder root rather than to a
        // URL with a trailing empty component.
        #expect(
            index.url(generation: 3, repIndex: 0, relativePath: "")
                == root.appendingPathComponent("folder"))
    }

    @Test("a generation that isn't current resolves nil")
    func staleGenerationResolvesNil() {
        let index = FileProviderOfferURLIndex()
        index.update(generation: 7, urls: [0: root.appendingPathComponent("report.pdf")])

        #expect(index.url(generation: 6, repIndex: 0, relativePath: nil) == nil)
        #expect(index.url(generation: 8, repIndex: 0, relativePath: nil) == nil)
        #expect(index.url(generation: 7, repIndex: 0, relativePath: nil) != nil)
    }

    @Test("clear() makes everything resolve nil")
    func clearDropsEverything() {
        let index = FileProviderOfferURLIndex()
        index.update(generation: 7, urls: [0: root.appendingPathComponent("report.pdf")])
        index.clear()

        #expect(index.url(generation: 7, repIndex: 0, relativePath: nil) == nil)
        // A fresh index resolves nothing either — clear() returns it to that state.
        #expect(FileProviderOfferURLIndex().url(generation: 7, repIndex: 0, relativePath: nil) == nil)
    }

    @Test("update replaces the prior generation wholesale rather than merging")
    func updateReplacesPriorGenerationWholesale() {
        let index = FileProviderOfferURLIndex()
        index.update(
            generation: 7,
            urls: [0: root.appendingPathComponent("a.txt"), 1: root.appendingPathComponent("b.txt")])
        index.update(generation: 8, urls: [0: root.appendingPathComponent("c.txt")])

        #expect(
            index.url(generation: 8, repIndex: 0, relativePath: nil)
                == root.appendingPathComponent("c.txt"))
        // Rep 1 existed only in the superseded offer; it must not survive into
        // the new generation.
        #expect(index.url(generation: 8, repIndex: 1, relativePath: nil) == nil)
        #expect(index.url(generation: 7, repIndex: 0, relativePath: nil) == nil)
    }
}
