import Foundation
import Testing

@testable import KernovaKit

@Suite("FileProviderItemIdentifier")
struct FileProviderItemIdentifierTests {
    @Test("make encodes generation and rep index into a decodable identifier")
    func makeRoundTrips() {
        for generation: UInt64 in [0, 1, 42, 65_535, 1 << 40] {
            for repIndex in [0, 1, 7, 65_535] {
                let id = FileProviderItemIdentifier.make(
                    generation: generation, repIndex: repIndex)
                let decoded = FileProviderItemIdentifier.decode(id)
                #expect(decoded?.generation == generation)
                #expect(decoded?.repIndex == repIndex)
            }
        }
    }

    @Test("decode rejects reserved container identifiers and garbage")
    func decodeRejectsNonOurs() {
        #expect(FileProviderItemIdentifier.decode("NSFileProviderRootContainerItemIdentifier") == nil)
        #expect(FileProviderItemIdentifier.decode("NSFileProviderWorkingSetContainerItemIdentifier") == nil)
        #expect(FileProviderItemIdentifier.decode("") == nil)
        #expect(FileProviderItemIdentifier.decode("clipfile") == nil)
        #expect(FileProviderItemIdentifier.decode("clipfile.1") == nil)
        #expect(FileProviderItemIdentifier.decode("clipfile.1.2.3") == nil)
        #expect(FileProviderItemIdentifier.decode("other.1.2") == nil)
        // Non-numeric / negative components.
        #expect(FileProviderItemIdentifier.decode("clipfile.x.0") == nil)
        #expect(FileProviderItemIdentifier.decode("clipfile.1.-1") == nil)
    }

    @Test("identifiers avoid the framework-reserved `/` and `:` characters")
    func identifierAvoidsReservedCharacters() {
        let id = FileProviderItemIdentifier.make(generation: 5, repIndex: 3)
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
                .init(generation: 9, repIndex: 0, filename: "report.pdf", byteCount: 1_234, uti: "com.adobe.pdf")
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
        let id = FileProviderItemIdentifier.make(generation: 9, repIndex: 0)
        let item = manifest.item(for: id)
        #expect(item?.filename == "report.pdf")
        #expect(item?.byteCount == 1_234)
        #expect(item?.uti == "com.adobe.pdf")
    }

    @Test("item(for:) returns nil for a stale generation or unknown rep")
    func itemLookupRejectsStale() {
        let manifest = makeManifest()
        // Same rep, different (superseded) generation.
        #expect(manifest.item(for: FileProviderItemIdentifier.make(generation: 8, repIndex: 0)) == nil)
        // Unknown rep index in the current generation.
        #expect(manifest.item(for: FileProviderItemIdentifier.make(generation: 9, repIndex: 1)) == nil)
        // Not one of ours.
        #expect(manifest.item(for: "garbage") == nil)
    }

    @Test("an item's itemIdentifier matches the shared encoder")
    func itemIdentifierMatchesEncoder() {
        let item = FileProviderManifest.Item(
            generation: 3, repIndex: 2, filename: "a.bin", byteCount: 1, uti: "public.data")
        #expect(item.itemIdentifier == FileProviderItemIdentifier.make(generation: 3, repIndex: 2))
    }

    @Test("the empty manifest carries no items and the no-offer sentinel generation")
    func emptyManifest() {
        #expect(FileProviderManifest.empty.items.isEmpty)
        #expect(FileProviderManifest.empty.generation == 0)
    }
}
