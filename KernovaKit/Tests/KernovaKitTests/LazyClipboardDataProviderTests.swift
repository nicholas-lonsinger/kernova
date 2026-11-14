import AppKit
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit
import KernovaSynchronization

/// Exercises the shared `LazyClipboardDataProvider`.
///
/// It is the on-demand `NSPasteboardItemDataProvider` that both the guest agent
/// (inbound paste) and the host app ("Copy to Mac") write to a pasteboard. The
/// callbacks are invoked directly so the tests stay deterministic and never
/// touch a live pasteboard.
@Suite("LazyClipboardDataProvider", .caseScoped)
struct LazyClipboardDataProviderTests {
    private let textType = NSPasteboard.PasteboardType("public.utf8-plain-text")

    /// A provider whose `provide` runs `insideFire` with the provider itself, the
    /// way a fire's event loop reaches back into it, then serves `bytes`; its
    /// finish releases it from `registry` and counts on `finishes`.
    private func makeRetainedProvider(
        registry: LazyClipboardProviderRegistry, finishes: Locked<Int>, finished: AsyncGate,
        bytes: Data, insideFire: @escaping @Sendable (LazyClipboardDataProvider) -> Void
    ) -> LazyClipboardDataProvider {
        let holder = Locked<LazyClipboardDataProvider?>(nil)
        let provider = LazyClipboardDataProvider(
            provide: { _ in
                if let provider = holder.withLock({ $0 }) { insideFire(provider) }
                return bytes
            },
            onFinished: {
                registry.release($0)
                finishes.withLock { $0 += 1 }
                finished.notify()
            })
        holder.withLock { $0 = provider }
        registry.retain([provider])
        return provider
    }

    @Test("a finish landing inside a fire is held until the fire returns, then delivered once")
    func finishInsideFireIsHeldUntilTheFireReturns() async throws {
        let bytes = Data("served".utf8)
        let registry = LazyClipboardProviderRegistry()
        let finished = AsyncGate()
        let finishes = Locked(0)
        let finishesSeenInsideFire = Locked(-1)
        let provider = makeRetainedProvider(
            registry: registry, finishes: finishes, finished: finished, bytes: bytes
        ) { provider in
            // What a retract of the write being served does from inside the
            // fire's event loop: the pasteboard finishes with the provider, whose
            // owner — the only strong reference in production — would let go.
            provider.pasteboardFinishedWithDataProvider(NSPasteboard.withUniqueName())
            let seen = finishes.withLock { $0 }
            finishesSeenInsideFire.withLock { $0 = seen }
        }

        let item = NSPasteboardItem()
        provider.pasteboard(nil, item: item, provideDataForType: textType)

        // The fire ran to completion still owned; the finish came after it.
        #expect(item.data(forType: textType) == bytes)
        #expect(finishesSeenInsideFire.withLock { $0 } == 0)
        try await finished.wait { finishes.withLock { $0 } == 1 }
        #expect(registry.countForTesting == 0)
    }
}
