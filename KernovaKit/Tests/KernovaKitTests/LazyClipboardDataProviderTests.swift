import AppKit
import Foundation
import Testing

@testable import KernovaKit

/// Exercises the shared `LazyClipboardDataProvider`.
///
/// It is the on-demand `NSPasteboardItemDataProvider` that both the guest agent
/// (inbound paste) and the host app ("Copy to Mac") write to a pasteboard. The
/// callbacks are invoked directly so the tests stay deterministic and never
/// touch a live pasteboard.
@Suite("LazyClipboardDataProvider")
struct LazyClipboardDataProviderTests {
    private let textType = NSPasteboard.PasteboardType("public.utf8-plain-text")

    @Test("provideDataForType sets the bytes produced by `provide` on the item")
    func providesBytesForType() {
        let bytes = Data("hello".utf8)
        let provider = LazyClipboardDataProvider(
            provide: { [textType] in $0 == textType ? bytes : nil },
            onFinished: { _ in })

        let item = NSPasteboardItem()
        provider.pasteboard(nil, item: item, provideDataForType: textType)
        #expect(item.data(forType: textType) == bytes)
    }

    @Test("a `provide` that returns nil leaves the type empty")
    func nilProvideLeavesTypeEmpty() {
        let provider = LazyClipboardDataProvider(
            provide: { _ in nil },
            onFinished: { _ in })

        let item = NSPasteboardItem()
        provider.pasteboard(nil, item: item, provideDataForType: textType)
        #expect(item.data(forType: textType) == nil)
    }

    @Test("provideDataForType is invoked with the exact type requested")
    func passesRequestedTypeThrough() {
        let fileType = NSPasteboard.PasteboardType.fileURL
        let box = TypeBox()
        let provider = LazyClipboardDataProvider(
            provide: {
                box.requested = $0
                return nil
            },
            onFinished: { _ in })

        provider.pasteboard(nil, item: NSPasteboardItem(), provideDataForType: fileType)
        #expect(box.requested == fileType)
    }

    @Test("pasteboardFinishedWithDataProvider invokes onFinished with self")
    func finishedFiresOnFinished() {
        let box = ProviderBox()
        let provider = LazyClipboardDataProvider(
            provide: { _ in nil },
            onFinished: { box.finished = $0 })

        provider.pasteboardFinishedWithDataProvider(NSPasteboard.withUniqueName())
        #expect(box.finished === provider)
    }

    /// Reference box so an escaping callback can record what type it saw without
    /// a mutable value capture.
    private final class TypeBox {
        var requested: NSPasteboard.PasteboardType?
    }

    /// Reference box so the `onFinished` callback can record the provider it was
    /// handed.
    private final class ProviderBox {
        var finished: LazyClipboardDataProvider?
    }
}
