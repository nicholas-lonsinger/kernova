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

/// Holds each dial until the test answers it.
final class ScriptedDialer: TransportDialer {
    private let pending = Locked<[@Sendable (Result<any ByteStream, DialFailure>) -> Void]>([])
    /// One element per dial, numbered from 1.
    let dials = Recorder<Int>()

    func dial(_ completion: @escaping @Sendable (Result<any ByteStream, DialFailure>) -> Void) {
        let count = pending.withLock { pending in
            pending.append(completion)
            return pending.count
        }
        dials.record(count)
    }

    /// Answers dial `number`, counted from 1.
    func answer(_ number: Int, _ result: Result<any ByteStream, DialFailure>) {
        let completion = pending.withLock { $0[number - 1] }
        completion(result)
    }
}

/// Accepts every action it offers and hands off at once, unless told to hold before or after accepting.
/// It can never confirm a cancel, so a cancel ends the request `.unconfirmed`.
final class FakePowerAdapter: PowerAdapter {
    private let reporter = Locked<PowerReporter?>(nil)
    let performed = Recorder<PowerRequestID>()
    let cancelled = Recorder<PowerRequestID>()
    let accepts: Bool
    let handsOff: Bool
    let initial: Availability<PowerOffer>

    init(
        accepts: Bool = true, handsOff: Bool = true,
        initial: Availability<PowerOffer> = .available(PowerOffer(actions: [.shutdown]))
    ) {
        self.accepts = accepts
        self.handsOff = handsOff
        self.initial = initial
    }

    func start(reporter: PowerReporter) {
        self.reporter.withLock { $0 = reporter }
        reporter.report(.availability(initial))
    }

    func perform(_ id: PowerRequestID, _ action: PowerAction) {
        performed.record(id)
        guard accepts else { return }
        let reporter = reporter.withLock { $0 }
        reporter?.report(.accepted(id))
        if handsOff { reporter?.report(.handedOff(id)) }
    }

    func cancel(_ id: PowerRequestID) {
        cancelled.record(id)
        report(.unconfirmed(id))
    }

    /// Reports `input` as the adapter would, from the test's thread.
    func report(_ input: PowerInput) {
        reporter.withLock { $0 }?.report(input)
    }
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

/// Serves `content` by position; a read at or past `stallAfter` never completes.
final class FakePayloadSource: UpdatePayloadSource {
    let content: Data
    let stallAfter: Int?
    /// Each read's offset and count, in order.
    let reads = Recorder<(offset: UInt64, count: Int)>()
    /// Each read held at the stall.
    let stalled = Recorder<UInt64>()

    init(content: Data, stallAfter: Int? = nil) {
        self.content = content
        self.stallAfter = stallAfter
    }

    func read(
        manifest: UpdateManifestValue, offset: UInt64, count: Int,
        _ completion: @escaping @Sendable (Result<Data, WireError>) -> Void
    ) {
        reads.record((offset, count))
        if let stallAfter, offset >= UInt64(stallAfter) { return stalled.record(offset) }
        let start = Int(clamping: min(offset, UInt64(content.count)))
        completion(.success(Data(content[start..<min(content.count, start + count)])))
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
