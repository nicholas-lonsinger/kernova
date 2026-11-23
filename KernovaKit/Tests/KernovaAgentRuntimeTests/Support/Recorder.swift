import KernovaPortableTestSupport
import KernovaSynchronization

/// Records values from any thread. Each waiter reads every value from its own start, so any number of
/// waiters see the same sequence.
final class Recorder<Element: Sendable>: Sendable {
    private struct State: Sendable {
        var all: [Element] = []
        var parked: [@Sendable () -> Void] = []
    }

    private let state = Locked(State())

    func record(_ element: Element) {
        let parked = state.withLock { state in
            state.all.append(element)
            defer { state.parked.removeAll() }
            return state.parked
        }
        for resume in parked { resume() }
    }

    /// Everything recorded so far.
    var elements: [Element] { state.withLock(\.all) }

    /// A cursor from the first value.
    func waiter() -> Waiter { Waiter(recorder: self, index: 0) }

    /// The value at `index`, once it is recorded before `backstop`'s deadline.
    fileprivate func element(at index: Int, within backstop: Backstop) async throws -> Element {
        while true {
            if let element = state.withLock({ index < $0.all.count ? $0.all[index] : nil }) { return element }
            try await backstop.park { resume in
                let ready = state.withLock { state -> Bool in
                    if index < state.all.count { return true }
                    state.parked.append { resume(()) }
                    return false
                }
                if ready { resume(()) }
            }
        }
    }

    struct Waiter: Sendable {
        let recorder: Recorder
        var index: Int

        /// The next value matching `predicate`, recorded before the `testWaitBackstop` deadline of a wait armed at
        /// `fileID`:`line`.
        mutating func next(
            fileID: String = #fileID, line: Int = #line, where predicate: (Element) -> Bool
        ) async throws -> Element {
            let backstop = Backstop("Recorder.next(where:)", fileID: fileID, line: line)
            while true {
                let element = try await recorder.element(at: index, within: backstop)
                index += 1
                if predicate(element) { return element }
            }
        }
    }
}
