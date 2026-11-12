import Foundation
import KernovaKit
import KernovaTestSupport
import Testing
import UniformTypeIdentifiers

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Exercises `HostClipboardPublisher.hostPasteboardItems` — the pure
/// grouping/staging step that turns resolved content into one
/// `ItemSpec` per inline-content block plus one per file payload.
///
/// Each spec promises a set of types and serves their bytes lazily through
/// `provide`; the tests drive that closure directly, so they cover both the
/// grouping and the on-demand read without touching a real `NSPasteboard`.
@Suite("HostClipboardPublisher pasteboard items", .caseScoped)
struct ClipboardHostPasteboardItemsTests {
    private let stagingRoot = TestStagingRoot()

    private func makeStaging() -> ClipboardFileStaging {
        ClipboardFileStaging(label: "hostwrite-test-\(UUID().uuidString)", root: stagingRoot.root)
    }

    private let fileURLType = ClipboardPasteboardPublisher.ItemSpec.fileURLType

    /// The file URL a spec serves for `.fileURL`, or `nil` when it promises none.
    private func fileURL(in spec: ClipboardPasteboardPublisher.ItemSpec) -> URL? {
        spec.provide(fileURLType)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(URL.init(string:))
    }

    @Test("two file payloads produce two items, each promising exactly one file URL")
    func twoFilesTwoItems() async throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let content = ClipboardContent(representations: [
            .init(uti: UTType.plainText.identifier, data: Data("alpha".utf8), filename: "a.txt"),
            .init(uti: UTType.plainText.identifier, data: Data("beta".utf8), filename: "b.txt"),
        ])
        let specs = try await HostClipboardPublisher.hostPasteboardItems(
            for: content, generation: 1, staging: staging)

        #expect(specs.count == 2)
        // A non-image file is file-only: exactly one `.fileURL`, no inline bytes.
        for spec in specs {
            #expect(spec.types == [fileURLType])
        }
        let urlA = try #require(fileURL(in: specs[0]))
        let urlB = try #require(fileURL(in: specs[1]))
        #expect(urlA.lastPathComponent == "a.txt")
        #expect(urlB.lastPathComponent == "b.txt")
        #expect(try Data(contentsOf: urlA) == Data("alpha".utf8))
        #expect(try Data(contentsOf: urlB) == Data("beta".utf8))
    }

    @Test("an image-file item promises both its inline image bytes and a file URL")
    func imageFileItemCarriesBoth() async throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let png = try makePNGData(width: 2, height: 2)
        let content = ClipboardContent(representations: [
            .init(uti: UTType.png.identifier, data: png, filename: "photo.png")
        ])
        let specs = try await HostClipboardPublisher.hostPasteboardItems(
            for: content, generation: 1, staging: staging)

        #expect(specs.count == 1)
        let spec = specs[0]
        let pngType = UTType.png.identifier
        #expect(Set(spec.types) == [pngType, fileURLType])
        // The inline image bytes are served lazily; the file URL stages the same.
        #expect(spec.provide(pngType) == png)
        let url = try #require(fileURL(in: spec))
        #expect(url.lastPathComponent == "photo.png")
        #expect(try Data(contentsOf: url) == png)
    }
}
