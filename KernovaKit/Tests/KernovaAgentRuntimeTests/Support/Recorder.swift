import KernovaSynchronization

/// Records values from any thread. Each waiter reads every value from its own start, so any number of
/// waiters see the same sequence.
final class Recorder<Element: Sendable>: Sendable {
    private struct State: Sendable {
        var all: [Element] = []
        var parked: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Locked(State())

    func record(_ element: Element) {
        let parked = state.withLock { state in
            state.all.append(element)
            defer { state.parked.removeAll() }
            return state.parked
        }
        for continuation in parked { continuation.resume() }
    }

    /// Everything recorded so far.
    var elements: [Element] { state.withLock(\.all) }

    /// A cursor from the first value.
    func waiter() -> Waiter { Waiter(recorder: self, index: 0) }

    /// A cursor from the next value recorded.
    func waiterFromNow() -> Waiter { Waiter(recorder: self, index: elements.count) }

    /// The value at `index`, once it is recorded.
    fileprivate func element(at index: Int) async -> Element {
        while true {
            if let element = state.withLock({ index < $0.all.count ? $0.all[index] : nil }) { return element }
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> Bool in
                    if index < state.all.count { return true }
                    state.parked.append(continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        }
    }

    struct Waiter: Sendable {
        let recorder: Recorder
        var index: Int

        /// The next value matching `predicate`.
        mutating func next(where predicate: (Element) -> Bool) async -> Element {
            while true {
                let element = await recorder.element(at: index)
                index += 1
                if predicate(element) { return element }
            }
        }
    }
}
