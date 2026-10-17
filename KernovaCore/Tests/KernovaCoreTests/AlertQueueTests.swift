import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Covers `AlertQueue` over requests that name the window they go to, and
/// windows named by strings.
@Suite("AlertQueue", .caseScoped)
struct AlertQueueTests {
    /// A request for `window` — or for none, when `nil` — whose premise holds
    /// while `holds` does.
    private struct Request: Equatable {
        let name: String
        let window: String?
        var holds = true
    }

    private typealias Queue = AlertQueue<Request, String>

    /// Takes everything `free` lets up, in the order the queue gives it, and
    /// what it dropped along the way.
    private func drain(
        _ queue: inout Queue, free: Set<String>
    ) -> (taken: [String], dropped: [String]) {
        var busy: Set<String> = []
        var taken: [String] = []
        var dropped: [String] = []
        while let (entry, window) = queue.takeNext(
            destination: \.window,
            isFree: { free.contains($0) && !busy.contains($0) },
            stillHolds: \.holds,
            drop: { dropped.append($0.name) })
        {
            busy.insert(window)
            taken.append(entry.request.name)
        }
        return (taken, dropped)
    }

    @Test("Each window takes one alert at a time, in the order raised")
    func oneAtATimeInOrder() {
        var queue = Queue()
        queue.enqueue(Request(name: "A1", window: "A"))
        queue.enqueue(Request(name: "A2", window: "A"))

        #expect(drain(&queue, free: ["A"]).taken == ["A1"])
        #expect(drain(&queue, free: ["A"]).taken == ["A2"])
    }

    @Test("An alert waiting on a busy window does not hold up one for another")
    func busyWindowHoldsUpNoOther() {
        var queue = Queue()
        queue.enqueue(Request(name: "A1", window: "A"))
        queue.enqueue(Request(name: "B1", window: "B"))

        #expect(drain(&queue, free: ["B"]).taken == ["B1"])
        #expect(queue.waiting.map(\.request.name) == ["A1"])
    }

    @Test("An alert routed nowhere is held, and stays")
    func unroutedIsHeld() {
        var queue = Queue()
        queue.enqueue(Request(name: "Held", window: nil))
        queue.enqueue(Request(name: "A1", window: "A"))

        #expect(drain(&queue, free: ["A"]).taken == ["A1"])
        #expect(queue.held(destination: \.window).map(\.name) == ["Held"])
    }

    @Test("An alert whose premise lapsed is dropped on the way to the next")
    func lapsedIsDropped() {
        var queue = Queue()
        queue.enqueue(Request(name: "Lapsed", window: "A", holds: false))
        queue.enqueue(Request(name: "A1", window: "A"))

        let result = drain(&queue, free: ["A"])

        #expect(result.dropped == ["Lapsed"])
        #expect(result.taken == ["A1"])
        #expect(queue.waiting.isEmpty)
    }

    @Test("An alert taken off a closing window goes back in the place its raising gave it")
    func requeueKeepsRaisingOrder() throws {
        var queue = Queue()
        queue.enqueue(Request(name: "First", window: "A"))
        queue.enqueue(Request(name: "Second", window: "B"))
        queue.enqueue(Request(name: "Third", window: "B"))
        let taken = queue.takeNext(
            destination: \.window, isFree: { $0 == "A" }, stillHolds: \.holds, drop: { _ in })
        let (first, _) = try #require(taken)

        queue.requeue(first)

        #expect(queue.waiting.map(\.request.name) == ["First", "Second", "Third"])
    }

    @Test("A window is awaited while an alert is routed to it")
    func awaitedWindow() {
        var queue = Queue()
        queue.enqueue(Request(name: "A1", window: "A"))

        #expect(queue.isAwaited("A", destination: \.window))
        #expect(!queue.isAwaited("B", destination: \.window))
    }
}
