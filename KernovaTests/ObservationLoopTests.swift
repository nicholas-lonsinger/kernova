import Testing
import Foundation
@testable import Kernova

@Suite("ObservationLoop Tests")
@MainActor
struct ObservationLoopTests {

    @Observable
    @MainActor
    final class Subject {
        var value: Int = 0
        var other: Int = 0
    }

    @MainActor
    final class Counter {
        var count = 0
        func increment() { count += 1 }
    }

    /// Yields the main actor multiple times so any queued `Task { @MainActor ... }`
    /// enqueued by the observation helper has an opportunity to run before assertions.
    private func drain() async {
        for _ in 0..<5 { await Task.yield() }
    }

    @Test("apply fires when a tracked property changes")
    func applyFiresOnChange() async {
        let subject = Subject()
        let counter = Counter()

        let loop = observeRecurring(
            track: { _ = subject.value },
            apply: { counter.increment() }
        )

        #expect(counter.count == 0)

        subject.value = 1
        await drain()

        #expect(counter.count == 1)
        _ = loop
    }

    @Test("apply re-fires on subsequent changes (re-registration works)")
    func applyReRegistersAfterFire() async {
        let subject = Subject()
        let counter = Counter()

        let loop = observeRecurring(
            track: { _ = subject.value },
            apply: { counter.increment() }
        )

        subject.value = 1
        await drain()
        #expect(counter.count == 1)

        subject.value = 2
        await drain()
        #expect(counter.count == 2)

        subject.value = 3
        await drain()
        #expect(counter.count == 3)

        _ = loop
    }

    @Test("apply does not fire for properties not read in track")
    func applyIgnoresUntrackedProperties() async {
        let subject = Subject()
        let counter = Counter()

        let loop = observeRecurring(
            track: { _ = subject.value },
            apply: { counter.increment() }
        )

        subject.other = 42
        await drain()

        #expect(counter.count == 0)
        _ = loop
    }

    @Test("cancel stops the loop")
    func cancelStopsLoop() async {
        let subject = Subject()
        let counter = Counter()

        let loop = observeRecurring(
            track: { _ = subject.value },
            apply: { counter.increment() }
        )

        subject.value = 1
        await drain()
        #expect(counter.count == 1)

        loop.cancel()

        subject.value = 2
        await drain()
        #expect(counter.count == 1)

        subject.value = 3
        await drain()
        #expect(counter.count == 1)
    }

    @Test("cancel is idempotent")
    func cancelIsIdempotent() async {
        let subject = Subject()
        let counter = Counter()

        let loop = observeRecurring(
            track: { _ = subject.value },
            apply: { counter.increment() }
        )

        loop.cancel()
        loop.cancel()
        loop.cancel()

        subject.value = 1
        await drain()
        #expect(counter.count == 0)
    }

    @Test("dropping the handle after cancel stops the loop even before any fire")
    func cancelBeforeAnyFire() async {
        let subject = Subject()
        let counter = Counter()

        let loop = observeRecurring(
            track: { _ = subject.value },
            apply: { counter.increment() }
        )

        loop.cancel()

        subject.value = 1
        await drain()

        #expect(counter.count == 0)
    }

    @Test("multiple independent loops can observe the same subject")
    func independentLoops() async {
        let subject = Subject()
        let counterA = Counter()
        let counterB = Counter()

        let loopA = observeRecurring(
            track: { _ = subject.value },
            apply: { counterA.increment() }
        )
        let loopB = observeRecurring(
            track: { _ = subject.value },
            apply: { counterB.increment() }
        )

        subject.value = 1
        await drain()
        #expect(counterA.count == 1)
        #expect(counterB.count == 1)

        loopA.cancel()

        subject.value = 2
        await drain()
        #expect(counterA.count == 1)
        #expect(counterB.count == 2)

        _ = loopB
    }
}
