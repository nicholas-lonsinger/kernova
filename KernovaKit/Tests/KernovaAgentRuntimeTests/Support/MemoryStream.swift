#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentRuntime
import KernovaSynchronization

/// One end of an in-memory connection: what one end writes, the other receives, in order, under the
/// `ByteStream` contract. Shutting either end down ends the other's read side with `.eof`.
final class MemoryStream: ByteStream {
    private struct State: Sendable {
        var queue: DispatchQueue?
        var handler: (@Sendable (ByteStreamEvent) -> Void)?
        var inbox: [Data] = []
        /// A `.received` was delivered and `readMore()` has not followed.
        var awaitingReadMore = false
        var pendingEnd: ByteStreamEnd?
        var endDelivered = false
        var isShutDown = false
        var isReleased = false
        /// While true, what this end writes is kept back from the far end.
        var holdsOutbound = false
        var heldOutbound: [Data] = []
        var released: (@Sendable () -> Void)?
    }

    private let state = Locked(State())
    private let far = Locked<MemoryStream?>(nil)
    /// How many times `shutdown()` was called.
    let shutdowns = Locked(0)

    private init() {}

    /// Two connected ends.
    static func pair() -> (MemoryStream, MemoryStream) {
        let a = MemoryStream()
        let b = MemoryStream()
        a.far.withLock { $0 = b }
        b.far.withLock { $0 = a }
        return (a, b)
    }

    /// Runs `released` once this end has let everything go, as a descriptor-backed stream does.
    func onRelease(_ released: @escaping @Sendable () -> Void) {
        state.withLock { $0.released = released }
    }

    /// Keeps back everything this end writes from now on, so the far end hears silence.
    func holdOutbound() {
        state.withLock { $0.holdsOutbound = true }
    }

    func start(on queue: DispatchQueue, _ handler: @escaping @Sendable (ByteStreamEvent) -> Void) {
        let shutBeforeStart = state.withLock { state -> Bool in
            state.queue = queue
            state.handler = handler
            return state.isShutDown
        }
        if shutBeforeStart {
            state.withLock { $0.pendingEnd = $0.pendingEnd ?? .failed(.shutDown) }
        }
        pump()
    }

    func readMore() {
        state.withLock { $0.awaitingReadMore = false }
        pump()
    }

    func write(_ chunks: [Data], _ completion: @escaping @Sendable (ByteStreamError?) -> Void) {
        let (queue, error, deliver) = state.withLock { state -> (DispatchQueue, ByteStreamError?, Data?) in
            guard let queue = state.queue else { preconditionFailure("a write before start") }
            guard !state.isShutDown else { return (queue, .shutDown, nil) }
            let bytes = chunks.reduce(into: Data()) { $0.append($1) }
            if state.holdsOutbound {
                state.heldOutbound.append(bytes)
                return (queue, nil, nil)
            }
            return (queue, nil, bytes)
        }
        if let deliver, !deliver.isEmpty { far.withLock { $0 }?.receive(deliver) }
        queue.async { completion(error) }
    }

    func shutdown() {
        shutdowns.withLock { $0 += 1 }
        let first = state.withLock { state -> Bool in
            guard !state.isShutDown else { return false }
            state.isShutDown = true
            if !state.endDelivered, state.pendingEnd == nil { state.pendingEnd = .failed(.shutDown) }
            return true
        }
        guard first else { return }
        far.withLock { $0 }?.farEnded()
        let neverStarted = state.withLock { $0.queue == nil }
        if neverStarted { release() } else { pump() }
        releaseIfDone()
    }

    private func receive(_ bytes: Data) {
        let accepted = state.withLock { state -> Bool in
            guard !state.isShutDown, state.pendingEnd == nil else { return false }
            var rest = bytes[...]
            while !rest.isEmpty {
                state.inbox.append(Data(rest.prefix(ByteStreamLimits.maxReceive)))
                rest = rest.dropFirst(ByteStreamLimits.maxReceive)
            }
            return true
        }
        if accepted { pump() }
    }

    private func farEnded() {
        state.withLock { state in
            if state.pendingEnd == nil, !state.endDelivered { state.pendingEnd = .eof }
        }
        pump()
    }

    /// Delivers the next event on the start queue, when one is due.
    private func pump() {
        guard let queue = state.withLock({ $0.queue }) else { return }
        queue.async { [self] in
            let (event, handler) = state.withLock {
                state -> (ByteStreamEvent?, (@Sendable (ByteStreamEvent) -> Void)?) in
                guard !state.endDelivered, !state.awaitingReadMore else { return (nil, nil) }
                if !state.inbox.isEmpty, !state.isShutDown {
                    state.awaitingReadMore = true
                    return (.received(state.inbox.removeFirst()), state.handler)
                }
                guard let end = state.pendingEnd else { return (nil, nil) }
                state.endDelivered = true
                return (.ended(end), state.handler)
            }
            guard let event, let handler else { return }
            handler(event)
            releaseIfDone()
        }
    }

    /// Releases once both the shutdown and the end are done.
    private func releaseIfDone() {
        if state.withLock({ $0.isShutDown && $0.endDelivered }) { release() }
    }

    private func release() {
        let released = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.isReleased else { return nil }
            state.isReleased = true
            return state.released
        }
        released?()
    }
}
