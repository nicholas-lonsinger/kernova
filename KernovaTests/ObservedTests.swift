import Testing
import Foundation
@testable import Kernova

@Suite("Observed Tests")
@MainActor
struct ObservedTests {
    @MainActor
    final class Storage<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    @Test("get returns the underlying value")
    func getsCurrentValue() {
        let storage = Storage("hello")
        let observed = Observed(
            get: { storage.value },
            set: { storage.value = $0 }
        )
        #expect(observed.get() == "hello")
    }

    @Test("set writes back through the closure")
    func setsBackToStorage() {
        let storage = Storage("hello")
        let observed = Observed(
            get: { storage.value },
            set: { storage.value = $0 }
        )
        observed.set("world")
        #expect(storage.value == "world")
    }

    @Test("readOnly factory ignores writes")
    func readOnlyDropsWrites() {
        let storage = Storage(42)
        let observed = Observed<Int>.readOnly { storage.value }
        observed.set(99)
        #expect(storage.value == 42)
    }

    @Test("wouldChange returns true when the candidate differs from current")
    func wouldChangeDiffers() {
        let storage = Storage(1)
        let observed = Observed(
            get: { storage.value },
            set: { storage.value = $0 }
        )
        #expect(observed.wouldChange(2))
    }

    @Test("wouldChange returns false when the candidate equals current")
    func wouldChangeMatches() {
        let storage = Storage(1)
        let observed = Observed(
            get: { storage.value },
            set: { storage.value = $0 }
        )
        #expect(!observed.wouldChange(1))
    }
}
