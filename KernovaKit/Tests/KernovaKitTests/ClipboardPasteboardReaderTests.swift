import AppKit
import Foundation
import KernovaTestSupport
import KernovaWire
import Testing
import UniformTypeIdentifiers

@testable import KernovaKit

@Suite("ClipboardPasteboardReader", .caseScoped)
@MainActor
struct ClipboardPasteboardReaderTests {
    // MARK: - Fixtures

    private let scratch = TestScratchDirectory(prefix: "reader-tests")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    // MARK: - File classification

    /// A file in the scratch directory this process cannot open.
    private func unreadableFile(_ name: String) throws -> URL {
        let file = scratch.url.appendingPathComponent(name)
        try Data("locked".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        return file
    }

    /// Guest Photos' ⌘C, its file URL naming a derivative in the Photos library that the agent cannot open.
    static func photosCopy(naming file: URL) -> [(type: NSPasteboard.PasteboardType, data: Data)] {
        let url = Data(file.absoluteString.utf8)
        let names: [(String, Data)] = [
            ("com.apple.photos.object-reference.asset", Data("asset".utf8)),
            ("public.jpeg", Data("jpeg".utf8)),
            ("CorePasteboardFlavorType 0x4A504547", Data("jpeg".utf8)),
            ("public.file-url", url),
            ("CorePasteboardFlavorType 0x6675726C", url),
            ("dyn.ah62d4rv4gu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn", url),
            ("NSFilenamesPboardType", url),
            ("dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu", url),
            ("Apple URL pasteboard type", url),
            ("dyn.ah62d4rv4gu8za0cuqf31k3pcr7u1e3cmsvw04vdbsvuyq4pqqznzexcdr71004pfnv61a3k", Data("cookie".utf8)),
            ("PXPasteboardItemDataFileURLCookieType", Data("cookie".utf8)),
            ("public.tiff", Data("tiff".utf8)),
            ("NeXT TIFF v4.0 pasteboard type", Data("tiff".utf8)),
        ]
        return names.map { (NSPasteboard.PasteboardType($0.0), $0.1) }
    }

    /// The types of ``photosCopy(naming:)`` that cross as data: all but those naming its file.
    static let photosCrossing = [
        "com.apple.photos.object-reference.asset", "public.jpeg", "CorePasteboardFlavorType 0x4A504547",
        "dyn.ah62d4rv4gu8za0cuqf31k3pcr7u1e3cmsvw04vdbsvuyq4pqqznzexcdr71004pfnv61a3k",
        "PXPasteboardItemDataFileURLCookieType", "public.tiff", "NeXT TIFF v4.0 pasteboard type",
    ]

    @Test(
        "an item whose file cannot be opened, with no promise, crosses as its other types, its file and aliases left out"
    )
    func unreadableFileItemCrossesAsItsData() async throws {
        let pasteboard = FakePasteboard()
        #expect(pasteboard.setItem(Self.photosCopy(naming: try unreadableFile("derivative.jpeg"))))
        guard
            case .offer(let source, let lost) = await ClipboardPasteboardReader.readOffer(
                from: pasteboard, publisher: .elsewhere(), sizeOf: nil)
        else { throw TestFailure("no offer") }
        #expect(lost == 1)
        let item = try #require(source.items.first)
        #expect(source.items.count == 1)
        #expect(item.representations.compactMap(\.type.appleUTI) == Self.photosCrossing)
        #expect(item.representations.allSatisfy { $0.storage == .inline })
        #expect(try await source.serve(item: 0, representation: 1).representation == .bytes(Data("jpeg".utf8)))
    }
}
