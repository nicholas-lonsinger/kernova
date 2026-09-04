import Foundation
import KernovaKit

/// Fans one batch of ``VMLibraryEvent`` values out to every stream
/// ``VMCommanding/events()`` handed out.
///
/// Continuations are held on the main actor and dropped when their stream ends,
/// so a consumer that stops iterating stops costing anything.
@MainActor
final class VMLibraryEventBroadcaster {
    private var continuations: [UUID: AsyncStream<[VMLibraryEvent]>.Continuation] = [:]

    /// Fires whenever the subscriber count changes, so an owner can start the
    /// work that feeds the stream only while somebody is reading it.
    var onSubscriberCountChanged: ((Int) -> Void)?

    func stream() -> AsyncStream<[VMLibraryEvent]> {
        let id = UUID()
        // `.unbounded` on purpose: dropping a batch would make a caller
        // waiting on a state wait forever, and the producer is human-scale.
        let (stream, continuation) = AsyncStream<[VMLibraryEvent]>.makeStream(
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

    /// Delivers `events` as one element; an empty batch delivers nothing.
    func emit(_ events: [VMLibraryEvent]) {
        guard !events.isEmpty else { return }
        for continuation in continuations.values {
            continuation.yield(events)
        }
    }

    private func drop(_ id: UUID) {
        guard continuations.removeValue(forKey: id) != nil else { return }
        onSubscriberCountChanged?(continuations.count)
    }
}
