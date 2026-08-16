import AppKit
import Foundation
import KernovaTestSupport
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

    /// A provider whose `provide` runs `insideFire` with the provider itself, the
    /// way a fire's event loop reaches back into it, then serves `bytes`; its
    /// finish releases it from `registry` and counts on `finishes`.
    private func makeRetainedProvider(
        registry: LazyClipboardProviderRegistry, finishes: Box<Int>, finished: AsyncGate,
        bytes: Data, insideFire: @escaping (LazyClipboardDataProvider) -> Void
    ) -> LazyClipboardDataProvider {
        let holder = Box<LazyClipboardDataProvider?>(nil)
        let provider = LazyClipboardDataProvider(
            provide: { _ in
                if let provider = holder.value { insideFire(provider) }
                return bytes
            },
            onFinished: {
                registry.release($0)
                finishes.value += 1
                finished.notify()
            })
        holder.value = provider
        registry.retain([provider])
        return provider
    }

    @Test("a finish landing inside a fire is held until the fire returns, then delivered once")
    func finishInsideFireIsHeldUntilTheFireReturns() async throws {
        let bytes = Data("served".utf8)
        let registry = LazyClipboardProviderRegistry()
        let finished = AsyncGate()
        let finishes = Box(0)
        let finishesSeenInsideFire = Box(-1)
        let pasteboard = NSPasteboard.withUniqueName()
        let provider = makeRetainedProvider(
            registry: registry, finishes: finishes, finished: finished, bytes: bytes
        ) { provider in
            // What a retract of the write being served does from inside the
            // fire's event loop: the pasteboard finishes with the provider, whose
            // owner — the only strong reference in production — would let go.
            provider.pasteboardFinishedWithDataProvider(pasteboard)
            finishesSeenInsideFire.value = finishes.value
        }

        let item = NSPasteboardItem()
        provider.pasteboard(nil, item: item, provideDataForType: textType)

        // The fire ran to completion still owned; the finish came after it.
        #expect(item.data(forType: textType) == bytes)
        #expect(finishesSeenInsideFire.value == 0)
        try await finished.wait { finishes.value == 1 }
        #expect(registry.countForTesting == 0)
    }

    @Test("a finish inside a nested fire waits for the outermost fire to return")
    func finishInsideNestedFireWaitsForTheOuterFire() async throws {
        let bytes = Data("served".utf8)
        let registry = LazyClipboardProviderRegistry()
        let finished = AsyncGate()
        let finishes = Box(0)
        let finishesSeenAfterNestedFire = Box(-1)
        let pasteboard = NSPasteboard.withUniqueName()
        let depth = Box(0)
        let provider = makeRetainedProvider(
            registry: registry, finishes: finishes, finished: finished, bytes: bytes
        ) { provider in
            depth.value += 1
            defer { depth.value -= 1 }
            if depth.value == 1 {
                // The outer fire's event loop runs a sibling flavor's fire, and the
                // finish lands inside that nested one.
                provider.pasteboard(nil, item: NSPasteboardItem(), provideDataForType: .fileURL)
                finishesSeenAfterNestedFire.value = finishes.value
            } else {
                provider.pasteboardFinishedWithDataProvider(pasteboard)
            }
        }

        let item = NSPasteboardItem()
        provider.pasteboard(nil, item: item, provideDataForType: textType)

        #expect(item.data(forType: textType) == bytes)
        #expect(finishesSeenAfterNestedFire.value == 0)
        try await finished.wait { finishes.value == 1 }
        #expect(registry.countForTesting == 0)
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
