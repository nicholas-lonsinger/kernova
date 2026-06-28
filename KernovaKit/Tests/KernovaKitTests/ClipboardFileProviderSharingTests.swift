import Foundation
import Testing

@testable import KernovaKit

@Suite("ClipboardFileProviderItemIdentifier")
struct ClipboardFileProviderItemIdentifierTests {
    @Test("make encodes generation and rep index into a decodable identifier")
    func makeRoundTrips() {
        for generation: UInt64 in [0, 1, 42, 65_535, 1 << 40] {
            for repIndex in [0, 1, 7, 65_535] {
                let id = ClipboardFileProviderItemIdentifier.make(
                    generation: generation, repIndex: repIndex)
                let decoded = ClipboardFileProviderItemIdentifier.decode(id)
                #expect(decoded?.generation == generation)
                #expect(decoded?.repIndex == repIndex)
            }
        }
    }

    @Test("decode rejects reserved container identifiers and garbage")
    func decodeRejectsNonOurs() {
        #expect(ClipboardFileProviderItemIdentifier.decode("NSFileProviderRootContainerItemIdentifier") == nil)
        #expect(ClipboardFileProviderItemIdentifier.decode("NSFileProviderWorkingSetContainerItemIdentifier") == nil)
        #expect(ClipboardFileProviderItemIdentifier.decode("") == nil)
        #expect(ClipboardFileProviderItemIdentifier.decode("clipfile") == nil)
        #expect(ClipboardFileProviderItemIdentifier.decode("clipfile.1") == nil)
        #expect(ClipboardFileProviderItemIdentifier.decode("clipfile.1.2.3") == nil)
        #expect(ClipboardFileProviderItemIdentifier.decode("other.1.2") == nil)
        // Non-numeric / negative components.
        #expect(ClipboardFileProviderItemIdentifier.decode("clipfile.x.0") == nil)
        #expect(ClipboardFileProviderItemIdentifier.decode("clipfile.1.-1") == nil)
    }

    @Test("identifiers avoid the framework-reserved `/` and `:` characters")
    func identifierAvoidsReservedCharacters() {
        let id = ClipboardFileProviderItemIdentifier.make(generation: 5, repIndex: 3)
        #expect(!id.contains("/"))
        #expect(!id.contains(":"))
    }
}

@Suite("ClipboardFileProviderManifest")
struct ClipboardFileProviderManifestTests {
    private func makeManifest() -> ClipboardFileProviderManifest {
        ClipboardFileProviderManifest(
            generation: 9,
            items: [
                .init(generation: 9, repIndex: 0, filename: "report.pdf", byteCount: 1_234, uti: "com.adobe.pdf")
            ])
    }

    @Test("encodes and decodes losslessly")
    func codableRoundTrips() throws {
        let manifest = makeManifest()
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ClipboardFileProviderManifest.self, from: data)
        #expect(decoded == manifest)
    }

    @Test("item(for:) resolves the matching identifier")
    func itemLookupResolves() {
        let manifest = makeManifest()
        let id = ClipboardFileProviderItemIdentifier.make(generation: 9, repIndex: 0)
        let item = manifest.item(for: id)
        #expect(item?.filename == "report.pdf")
        #expect(item?.byteCount == 1_234)
        #expect(item?.uti == "com.adobe.pdf")
    }

    @Test("item(for:) returns nil for a stale generation or unknown rep")
    func itemLookupRejectsStale() {
        let manifest = makeManifest()
        // Same rep, different (superseded) generation.
        #expect(manifest.item(for: ClipboardFileProviderItemIdentifier.make(generation: 8, repIndex: 0)) == nil)
        // Unknown rep index in the current generation.
        #expect(manifest.item(for: ClipboardFileProviderItemIdentifier.make(generation: 9, repIndex: 1)) == nil)
        // Not one of ours.
        #expect(manifest.item(for: "garbage") == nil)
    }

    @Test("an item's itemIdentifier matches the shared encoder")
    func itemIdentifierMatchesEncoder() {
        let item = ClipboardFileProviderManifest.Item(
            generation: 3, repIndex: 2, filename: "a.bin", byteCount: 1, uti: "public.data")
        #expect(item.itemIdentifier == ClipboardFileProviderItemIdentifier.make(generation: 3, repIndex: 2))
    }

    @Test("the empty manifest carries no items and the no-offer sentinel generation")
    func emptyManifest() {
        #expect(ClipboardFileProviderManifest.empty.items.isEmpty)
        #expect(ClipboardFileProviderManifest.empty.generation == 0)
    }
}
