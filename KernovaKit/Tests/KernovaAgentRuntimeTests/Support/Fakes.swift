#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaSynchronization
import KernovaWire

/// Records values from any thread and lets one test task wait for them in order.
final class Recorder<Element: Sendable>: Sendable {
    private let all = Locked<[Element]>([])
    private let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Element.self)
    }

    func record(_ element: Element) {
        all.withLock { $0.append(element) }
        continuation.yield(element)
    }

    /// Everything recorded so far.
    var elements: [Element] { all.withLock { $0 } }

    /// A cursor over every element, from the first.
    func waiter() -> Waiter { Waiter(iterator: stream.makeAsyncIterator()) }

    /// A cursor over the elements recorded from now on. Only for elements recorded from one serial
    /// queue, whose stream order is their recording order.
    func waiterFromNow() -> Waiter {
        Waiter(iterator: stream.makeAsyncIterator(), skip: elements.count)
    }

    struct Waiter {
        var iterator: AsyncStream<Element>.Iterator
        var skip = 0

        /// The next element matching `predicate`; nil only when the wait is cancelled.
        mutating func next(where predicate: (Element) -> Bool) async -> Element? {
            while let element = await iterator.next() {
                if skip > 0 {
                    skip -= 1
                    continue
                }
                if predicate(element) { return element }
            }
            return nil
        }
    }
}

/// A stream wrapper that can hold back what the inner stream delivers, and reports each write's start
/// and completion.
final class GatedStream: ByteStream {
    private struct State: Sendable {
        var gated = false
        var held: [ByteStreamEvent] = []
        var queue: DispatchQueue?
        var handler: (@Sendable (ByteStreamEvent) -> Void)?
    }

    private let inner: any ByteStream
    private let state = Locked(State())
    /// Each write's start (`nil`) and completion (`.some(error)`).
    let writes = Recorder<ByteStreamError??>()

    init(_ inner: any ByteStream) {
        self.inner = inner
    }

    func start(on queue: DispatchQueue, _ handler: @escaping @Sendable (ByteStreamEvent) -> Void) {
        state.withLock {
            $0.queue = queue
            $0.handler = handler
        }
        inner.start(on: queue) { [self] event in
            let deliver = state.withLock { state -> Bool in
                if state.gated { state.held.append(event) }
                return !state.gated
            }
            if deliver { handler(event) }
        }
    }

    func readMore() { inner.readMore() }

    func write(_ chunks: [Data], _ completion: @escaping @Sendable (ByteStreamError?) -> Void) {
        writes.record(nil)
        inner.write(chunks) { [writes] error in
            writes.record(.some(error))
            completion(error)
        }
    }

    func shutdown() { inner.shutdown() }

    /// Holds every later event until `release()`.
    func gate() {
        state.withLock { $0.gated = true }
    }

    /// Delivers what was held, in order, and stops holding.
    func release() {
        let (queue, handler, held) = state.withLock { state in
            state.gated = false
            defer { state.held.removeAll() }
            return (state.queue, state.handler, state.held)
        }
        guard let queue, let handler else { return }
        queue.async { held.forEach(handler) }
    }
}

/// Hands out one stream, then fails for good.
final class OneShotDialer: TransportDialer {
    private let stream = Locked<(any ByteStream)?>(nil)
    let dials = Recorder<Int>()

    init(_ stream: any ByteStream) {
        self.stream.withLock { $0 = stream }
    }

    func dial(_ completion: @escaping @Sendable (Result<any ByteStream, DialFailure>) -> Void) {
        let next = stream.withLock { stream in
            defer { stream = nil }
            return stream
        }
        dials.record(dials.elements.count + 1)
        completion(next.map { .success($0) } ?? .failure(.permanent))
    }
}

/// Accepts every action it offers; hands off at once unless told to hold.
final class FakePowerAdapter: PowerAdapter {
    private let reporter = Locked<PowerReporter?>(nil)
    let performed = Recorder<PowerRequestID>()
    let handsOff: Bool

    init(handsOff: Bool = true) {
        self.handsOff = handsOff
    }

    func start(reporter: PowerReporter) {
        self.reporter.withLock { $0 = reporter }
        reporter.report(.availability(.available(PowerOffer(actions: [.shutdown, .restart]))))
    }

    func perform(_ id: PowerRequestID, _ action: PowerAction) {
        performed.record(id)
        let reporter = reporter.withLock { $0 }
        reporter?.report(.accepted(id))
        if handsOff { reporter?.report(.handedOff(id)) }
    }

    func cancel(_ id: PowerRequestID) {}
}

/// Writes pulls to memory and installs a payload whose bytes match `expected`.
final class FakeInstaller: UpdateInstaller {
    private let reporter = Locked<UpdateReporter?>(nil)
    private let received = Locked<[UpdatePullID: Data]>([:])
    let calls = Recorder<String>()
    let expected: Data

    init(expected: Data) {
        self.expected = expected
    }

    func start(reporter: UpdateReporter) {
        self.reporter.withLock { $0 = reporter }
        reporter.report(.availability(.available(UpdateOffer(formats: [.executable]))))
    }

    func recordRejected(_ hash: Data) { calls.record("recordRejected") }
    func clearRejected() { calls.record("clearRejected") }

    func write(_ id: UpdatePullID, _ bytes: Data) {
        received.withLock { $0[id, default: Data()].append(bytes) }
        reporter.withLock { $0 }?.report(.consumed(id, bytes.count))
    }

    func complete(_ id: UpdatePullID, _ manifest: UpdateManifestValue) {
        let bytes = received.withLock { $0[id] ?? Data() }
        calls.record("complete \(bytes.count)")
        let reporter = reporter.withLock { $0 }
        if bytes == expected {
            reporter?.report(.installed(id))
        } else {
            reporter?.report(.rejected(id, WireError(.updateHashMismatch)))
        }
    }

    func abort(_ id: UpdatePullID) { calls.record("abort") }
}

/// Serves `content`; with `stallAfter`, holds every read past that many bytes.
final class FakePayloadSource: UpdatePayloadSource {
    let content: Data
    let stallAfter: Int?
    private let served = Locked<[UpdatePullID: Int]>([:])
    let stalled = Recorder<UpdatePullID>()

    init(content: Data, stallAfter: Int? = nil) {
        self.content = content
        self.stallAfter = stallAfter
    }

    func read(
        _ id: UpdatePullID, manifest: UpdateManifestValue, maxBytes: Int,
        _ completion: @escaping @Sendable (Result<Data, WireError>) -> Void
    ) {
        let slice = served.withLock { served -> Data? in
            let offset = served[id, default: 0]
            if let stallAfter, offset >= stallAfter { return nil }
            let end = min(content.count, offset + maxBytes)
            served[id] = end
            return Data(content[offset..<end])
        }
        guard let slice else { return stalled.record(id) }
        completion(.success(slice))
    }

    /// A deterministic payload of `count` bytes: a block of prime length repeated, so no two frames at
    /// different offsets carry the same bytes.
    static func payload(_ count: Int) -> Data {
        let block = Data((0..<4_093).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 7) })
        var payload = Data(capacity: count + block.count)
        while payload.count < count { payload.append(block) }
        return payload.prefix(count)
    }
}
