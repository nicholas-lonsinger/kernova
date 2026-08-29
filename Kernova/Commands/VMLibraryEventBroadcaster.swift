import Foundation
import KernovaKit

/// Fans one ``VMLibraryEvent`` out to every stream ``VMCommanding/events()``
/// handed out.
///
/// Continuations are held on the main actor and dropped when their stream ends,
/// so a consumer that stops iterating stops costing anything.
@MainActor
final class VMLibraryEventBroadcaster {
    private var continuations: [UUID: AsyncStream<VMLibraryEvent>.Continuation] = [:]

    /// Fires whenever the subscriber count changes, so an owner can start the
    /// work that feeds the stream only while somebody is reading it.
    var onSubscriberCountChanged: ((Int) -> Void)?

    var subscriberCount: Int { continuations.count }

    func stream() -> AsyncStream<VMLibraryEvent> {
        let id = UUID()
        // `.unbounded` on purpose: dropping an event would make a caller
        // waiting on a state wait forever, and the producer is human-scale.
        let (stream, continuation) = AsyncStream<VMLibraryEvent>.makeStream(
            bufferingPolicy: .unbounded)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.drop(id)
            }
        }
        continuations[id] = continuation
        onSubscriberCountChanged?(continuations.count)
        return stream
    }

    func emit(_ event: VMLibraryEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    /// Ends every stream — the teardown an owner runs when it stops producing.
    func finish() {
        let held = continuations
        continuations.removeAll()
        for continuation in held.values { continuation.finish() }
        onSubscriberCountChanged?(0)
    }

    private func drop(_ id: UUID) {
        guard continuations.removeValue(forKey: id) != nil else { return }
        onSubscriberCountChanged?(continuations.count)
    }
}
