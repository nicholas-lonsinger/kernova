import Foundation

/// The alerts waiting for a window, in the order they were raised, and the
/// rule that takes them off: each window takes the alerts routed to it in
/// raising order, and an alert waiting on one window never holds up another.
///
/// Where each alert goes, whether a window is free, and whether an alert's
/// premise still holds are read when an alert is about to be taken, from the
/// closures each call is handed — so routing follows the windows as they
/// stand then, not as they stood when the alert was raised.
struct AlertQueue<Request, Window: Hashable> {
    /// A request waiting for its window, numbered in the order it was raised.
    struct Entry {
        let sequence: Int
        let request: Request
    }

    /// Every request waiting for its window, in the order raised.
    private(set) var waiting: [Entry] = []
    private var nextSequence = 0

    /// Puts `request` at the back of the queue.
    mutating func enqueue(_ request: Request) {
        waiting.append(Entry(sequence: nextSequence, request: request))
        nextSequence += 1
    }

    /// Puts an entry taken off a window back among the waiting, in the place
    /// its raising gave it.
    mutating func requeue(_ entry: Entry) {
        let index = waiting.firstIndex { $0.sequence > entry.sequence } ?? waiting.endIndex
        waiting.insert(entry, at: index)
    }

    /// The first waiting entry routed to a window that is free, taken out of
    /// the queue with that window.
    ///
    /// Every entry ahead of it whose premise lapsed — `stillHolds` answers
    /// `false` — is taken out too and handed to `drop`. An entry routed
    /// nowhere stays.
    mutating func takeNext(
        destination: (Request) -> Window?,
        isFree: (Window) -> Bool,
        stillHolds: (Request) -> Bool,
        drop: (Request) -> Void
    ) -> (entry: Entry, window: Window)? {
        var index = 0
        while index < waiting.count {
            let entry = waiting[index]
            guard stillHolds(entry.request) else {
                waiting.remove(at: index)
                drop(entry.request)
                continue
            }
            if let window = destination(entry.request), isFree(window) {
                waiting.remove(at: index)
                return (entry, window)
            }
            index += 1
        }
        return nil
    }

    /// The waiting requests routed to no window — the ones held.
    func held(destination: (Request) -> Window?) -> [Request] {
        waiting.filter { destination($0.request) == nil }.map(\.request)
    }

    /// Whether any waiting request is routed to `window`, so a question asked
    /// there now would go ahead of it.
    func isAwaited(_ window: Window, destination: (Request) -> Window?) -> Bool {
        waiting.contains { destination($0.request) == window }
    }
}
