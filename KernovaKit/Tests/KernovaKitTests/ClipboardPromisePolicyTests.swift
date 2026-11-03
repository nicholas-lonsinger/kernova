import Foundation
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaKit

/// Unit tests for the receive-side gate both peers apply to an offer's items
/// before a byte of it crosses.
@Suite("ClipboardPromisePolicy", .caseScoped)
struct ClipboardPromisePolicyTests {
    private let fileURLType = ClipboardPasteboardPublisher.ItemSpec.fileURLType

    private func inline(_ uti: String = ClipboardContent.utf8TextUTI, size: Int = 8) -> Representation {
        .make(TypeDescriptor(appleUTI: uti), .inline, size: size)
    }

    private func file(_ name: String, uti: String = "public.data", size: Int = 8) -> Representation {
        .make(TypeDescriptor(appleUTI: uti), .file, size: size, name: name)
    }

    private func item(_ representations: Representation...) -> OfferedItem {
        var item = OfferedItem()
        item.representations = representations
        return item
    }

    // MARK: - keeps

    @Test("an ordinary inline representation is kept")
    func keepsInlineRepresentation() {
        #expect(ClipboardPromisePolicy.keeps(inline()))
    }

    @Test("an identity-skipped type is never kept")
    func dropsIdentitySkippedTypes() {
        #expect(!ClipboardPromisePolicy.keeps(inline("public.file-url")))
        #expect(!ClipboardPromisePolicy.keeps(inline(ClipboardSnapshotPolicy.concealedMarkerUTI)))
    }

    @Test("a representation of unknown size is kept: the sender read no bytes")
    func keepsRepresentationsOfUnknownSize() {
        #expect(ClipboardPromisePolicy.keeps(inline(size: 0)))
        #expect(ClipboardPromisePolicy.keeps(file("empty.txt", size: 0)))
    }

    @Test("an inline type no Mac pasteboard names is not kept; a MIME type alone maps")
    func keepsOnlyTypesAMacNames() {
        var windowsOnly = TypeDescriptor()
        windowsOnly.native = [NativeTypeNamespace.windowsClipboardFormat.qualified("CF_DIB")]
        #expect(!ClipboardPromisePolicy.keeps(.make(windowsOnly, .inline, size: 8)))

        var mimeOnly = TypeDescriptor()
        mimeOnly.mime = "image/png"
        #expect(mimeOnly.appleUTI == "public.png")
        #expect(ClipboardPromisePolicy.keeps(.make(mimeOnly, .inline, size: 8)))
    }

    @Test("an unrecognized storage is not kept")
    func dropsUnspecifiedStorage() {
        #expect(!ClipboardPromisePolicy.keeps(.make(TypeDescriptor(appleUTI: "public.data"), .unspecified, size: 8)))
    }

    // MARK: - servesFileURL

    @Test("only a kept FILE or FOLDER serves .fileURL")
    func servesFileURLForFilesAndFolders() {
        #expect(ClipboardPromisePolicy.servesFileURL(file("photo.png")))
        #expect(
            ClipboardPromisePolicy.servesFileURL(
                .make(TypeDescriptor(appleUTI: "public.folder"), .folder, size: 0, name: "Album")))
        #expect(!ClipboardPromisePolicy.servesFileURL(inline()))
        #expect(!ClipboardPromisePolicy.servesFileURL(inline("public.file-url")))
    }

    // MARK: - promisedTypes

    @Test("an item's best representation of each type serves it, and one file URL at most")
    func promisedTypesTakeTheFirstOfEachType() {
        let types = ClipboardPromisePolicy.promisedTypes(
            for: item(
                file("a.png", uti: "public.png"), inline("public.png"), inline("public.png"),
                file("b.png", uti: "public.png"), inline("public.file-url")))
        #expect(types.map(\.pasteboardType) == [fileURLType, "public.png"])
        #expect(types.map(\.representation) == [0, 1])
    }

    @Test("withholding file URLs leaves an item's inline types")
    func withholdingFileURLsLeavesInlineTypes() {
        let types = ClipboardPromisePolicy.promisedTypes(
            for: item(file("a.png", uti: "public.png"), inline("public.png")), servingFileURLs: false)
        #expect(types.map(\.pasteboardType) == ["public.png"])
    }

    // MARK: - Paste budget

    @Test("the paste-bound total counts only the .fileURL-serving reps")
    func totalsOnlyFileServingReps() {
        let items = [
            item(file("a.bin", size: 100)),
            item(inline(size: 200)),
            item(file("b.bin", size: 300), file("c.bin", size: 400)),
        ]
        #expect(ClipboardPromisePolicy.pasteBudget(items, limit: .max).total == 400)
    }

    @Test("the paste-bound total saturates rather than wrapping")
    func totalSaturates() {
        var huge = file("a.bin")
        huge.sizeEstimate = .max
        let items = [item(huge), item(file("b.bin", size: 1))]
        #expect(ClipboardPromisePolicy.pasteBudget(items, limit: .max).total == .max)
    }

    @Test("a set exactly at the cap is within budget, one byte over is not")
    func atCapIsWithinBudget() {
        let items = [item(file("a.bin", size: 100))]
        #expect(!ClipboardPromisePolicy.pasteBudget(items, limit: 100).exceeds)
        #expect(ClipboardPromisePolicy.pasteBudget(items, limit: 99).exceeds)
        #expect(ClipboardPromisePolicy.pasteBudget(items, limit: 99).limit == 99)
    }
}
