import AppKit
import Foundation
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaKit

/// The one place a clipboard publication reaches a pasteboard: how every write
/// is marked, what a failed one leaves behind, when a write is still this
/// publisher's to withdraw, and how a plan's promised types reach their bytes.
@Suite("ClipboardPasteboardPublisher", .caseScoped)
@MainActor
struct ClipboardPasteboardPublisherTests {
    private let textUTI = NSPasteboard.PasteboardType.string.rawValue
    private let offer = Data(repeating: 1, count: 16)
    private let otherOffer = Data(repeating: 2, count: 16)

    /// Answers every pull with `bytes` and `url`, counting nothing.
    private final class Puller: ClipboardItemPulling {
        let bytes: Data?
        let url: URL?
        init(bytes: Data? = nil, url: URL? = nil) {
            self.bytes = bytes
            self.url = url
        }
        func pullBytes(item: Int, representation: Int, completion: @escaping @Sendable (Data?) -> Void) {
            completion(bytes)
        }
        func pullFile(item: Int, representation: Int, completion: @escaping @Sendable (URL?) -> Void) {
            completion(url)
        }
    }

    /// A write serving the offer `token`, its specs the test's own.
    private func serving(_ token: Data) -> ClipboardWriteSource {
        ClipboardWriteSource(offer: token, items: [], concealed: false, servingFileURLs: true, puller: Puller())
    }

    /// A write serving `offer`.
    private var servingOffer: ClipboardWriteSource { serving(offer) }

    private func makeSpec(_ uti: String, bytes: Data) -> ClipboardPasteboardPublisher.ItemSpec {
        ClipboardPasteboardPublisher.ItemSpec(types: [uti]) { _ in bytes }
    }

    // MARK: - Writing

    @Test("every write marks its contents host-only")
    func everyWriteIsMarkedHostOnly() {
        let pasteboard = FakeWritePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry)

        publisher.write([makeSpec(textUTI, bytes: Data("one".utf8))], source: servingOffer)
        publisher.write([makeSpec(textUTI, bytes: Data("two".utf8))], source: serving(otherOffer))

        #expect(pasteboard.prepareCount == 2)
        #expect(pasteboard.lastPrepareOptions == .currentHostOnly)
    }
}
