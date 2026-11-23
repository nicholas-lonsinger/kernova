import KernovaTestSupport
import Testing

@testable import KernovaCore

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

    @Test("An alert routed nowhere is held, and stays")
    func unroutedIsHeld() {
        var queue = Queue()
        queue.enqueue(Request(name: "Held", window: nil))
        queue.enqueue(Request(name: "A1", window: "A"))

        #expect(drain(&queue, free: ["A"]).taken == ["A1"])
        #expect(queue.held(destination: \.window).map(\.name) == ["Held"])
    }
}
