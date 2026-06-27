import Foundation
import Testing

@testable import KernovaKit

/// Exercises the pure `ClipboardPasteboardItemPlan.plan(for:)` grouping shared by
/// the host "Copy to Mac" path and the guest inbound-paste path.
@Suite("ClipboardPasteboardItemPlan.plan")
struct ClipboardPasteboardItemPlanTests {
    private func inline(_ uti: String) -> ClipboardRepresentationDescriptor {
        ClipboardRepresentationDescriptor(uti: uti, filename: "", isInline: true, isPromisable: true)
    }

    private func file(
        _ uti: String, _ filename: String, isInline: Bool
    ) -> ClipboardRepresentationDescriptor {
        ClipboardRepresentationDescriptor(
            uti: uti, filename: filename, isInline: isInline, isPromisable: true)
    }

    @Test("plain text becomes one inline item with one type")
    func plainText() {
        let plan = ClipboardPasteboardItemPlan.plan(for: [inline("public.utf8-plain-text")])
        #expect(plan.items.count == 1)
        #expect(plan.items[0].types.count == 1)
        let type = plan.items[0].types[0]
        #expect(type.uti == "public.utf8-plain-text")
        #expect(type.representationIndex == 0)
        #expect(!type.isFileURL)
    }

    @Test("two non-image files become two items, each promising only .fileURL")
    func twoNonImageFiles() {
        let plan = ClipboardPasteboardItemPlan.plan(for: [
            file("public.plain-text", "a.txt", isInline: false),
            file("public.plain-text", "b.txt", isInline: false),
        ])
        #expect(plan.items.count == 2)
        for (offset, item) in plan.items.enumerated() {
            #expect(item.types.count == 1)
            #expect(item.types[0].isFileURL)
            #expect(item.types[0].representationIndex == offset)
        }
    }

    @Test("an image file promises its image UTI then .fileURL in one item")
    func imageFile() {
        let plan = ClipboardPasteboardItemPlan.plan(for: [file("public.png", "p.png", isInline: true)])
        #expect(plan.items.count == 1)
        let types = plan.items[0].types
        #expect(types.count == 2)
        #expect(types[0].uti == "public.png")
        #expect(!types[0].isFileURL)
        #expect(types[1].isFileURL)
        #expect(types[0].representationIndex == 0)
        #expect(types[1].representationIndex == 0)
    }

    @Test("inline content and a file payload order the inline item first")
    func inlineThenFile() {
        let plan = ClipboardPasteboardItemPlan.plan(for: [
            inline("public.utf8-plain-text"),
            file("public.plain-text", "a.txt", isInline: false),
        ])
        #expect(plan.items.count == 2)
        // Inline item first.
        #expect(plan.items[0].types.allSatisfy { !$0.isFileURL })
        #expect(plan.items[0].types[0].representationIndex == 0)
        // File item second.
        #expect(plan.items[1].types.contains { $0.isFileURL })
        #expect(plan.items[1].types[0].representationIndex == 1)
    }

    @Test("inline UTIs dedup first-wins and preserve order")
    func inlineDedup() {
        let plan = ClipboardPasteboardItemPlan.plan(for: [
            inline("public.rtf"),  // index 0 — richest first
            inline("public.utf8-plain-text"),  // index 1
            inline("public.rtf"),  // index 2 — duplicate UTI, dropped
        ])
        #expect(plan.items.count == 1)
        let types = plan.items[0].types
        #expect(types.map(\.uti) == ["public.rtf", "public.utf8-plain-text"])
        // First occurrence wins: the surviving rtf keeps index 0, not 2.
        #expect(types[0].representationIndex == 0)
        #expect(types[1].representationIndex == 1)
    }

    @Test("a directory becomes one item promising only .fileURL")
    func directory() {
        let plan = ClipboardPasteboardItemPlan.plan(for: [
            // A directory never inlines, so isInline is false.
            file("public.folder", "Docs", isInline: false)
        ])
        #expect(plan.items.count == 1)
        #expect(plan.items[0].types.count == 1)
        #expect(plan.items[0].types[0].isFileURL)
    }

    @Test("non-promisable reps are skipped while survivors keep their original index")
    func nonPromisableSkippedIndicesPreserved() {
        let plan = ClipboardPasteboardItemPlan.plan(for: [
            inline("public.utf8-plain-text"),  // index 0 — promisable
            ClipboardRepresentationDescriptor(  // index 1 — NOT promisable, skipped
                uti: "org.nspasteboard.TransientType", filename: "", isInline: true,
                isPromisable: false),
            file("public.plain-text", "a.txt", isInline: false),  // index 2 — promisable file
        ])
        #expect(plan.items.count == 2)
        // Inline item keeps index 0 (the skipped rep didn't shift it).
        #expect(plan.items[0].types[0].representationIndex == 0)
        // File item resolves to the ORIGINAL index 2, not a compacted 1.
        #expect(plan.items[1].types[0].representationIndex == 2)
    }
}
