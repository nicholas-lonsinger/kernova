import Testing
import Foundation
@testable import Kernova

@Suite("ModalFlagObserver Tests")
@MainActor
struct ModalFlagObserverTests {
    @Observable
    @MainActor
    final class FlagSource {
        var flag: Bool = false
    }

    @MainActor
    final class Counter {
        var count = 0
        func increment() { count += 1 }
    }

    private func drain() async {
        for _ in 0..<5 { await Task.yield() }
    }

    @Test("present fires on false → true transition")
    func risingEdgeFires() async {
        let source = FlagSource()
        let counter = Counter()

        let loop = observeModalFlag(
            { source.flag }
        ) {
            counter.increment()
        }

        source.flag = true
        await drain()
        #expect(counter.count == 1)
        _ = loop
    }

    @Test("present does not fire on true → false transition")
    func fallingEdgeIgnored() async {
        let source = FlagSource()
        let counter = Counter()
        source.flag = true

        let loop = observeModalFlag(
            { source.flag }
        ) {
            counter.increment()
        }

        // The initial state is already `true`; we should not have fired.
        await drain()
        #expect(counter.count == 0)

        source.flag = false
        await drain()
        #expect(counter.count == 0)
        _ = loop
    }

    @Test("present re-fires on every false → true transition")
    func multipleRisingEdges() async {
        let source = FlagSource()
        let counter = Counter()

        let loop = observeModalFlag(
            { source.flag }
        ) {
            counter.increment()
        }

        source.flag = true
        await drain()
        source.flag = false
        await drain()
        source.flag = true
        await drain()
        source.flag = false
        await drain()
        source.flag = true
        await drain()

        #expect(counter.count == 3)
        _ = loop
    }

    @Test("cancel stops the loop")
    func cancelStops() async {
        let source = FlagSource()
        let counter = Counter()

        let loop = observeModalFlag(
            { source.flag }
        ) {
            counter.increment()
        }

        source.flag = true
        await drain()
        #expect(counter.count == 1)

        loop.cancel()

        source.flag = false
        await drain()
        source.flag = true
        await drain()

        #expect(counter.count == 1)
    }
}
