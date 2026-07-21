import Darwin
import FileProvider
import Foundation
import KernovaTestSupport

@testable import KernovaKit

/// A test failure with a message, thrown by the streaming-engine test helpers.
struct StreamTestFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// A `@Sendable`-safe mutable cell — lets a synchronous test closure record what it
/// observed from a concurrency-checked context.
///
/// Shared across the package test suites (`@testable import` visibility) so the
/// lock-guarded cell has one source of truth.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

// MARK: - File Provider servicing test config

/// Builds a `FileProviderConfig` for File-Provider-servicing tests: no
/// code-signing pins (so a source/connector can be constructed without
/// touching production identifiers), and a fresh, UUID-suffixed service name /
/// reconnect notification name each call, so parallel tests can never
/// cross-talk (Darwin notification names are a flat, process-global
/// namespace).
func makeTestFileProviderConfig() -> FileProviderConfig {
    let unique = UUID().uuidString
    return FileProviderConfig(
        appGroupIdentifier: "8MT4P4GZL2.app.kernova.test",
        serviceName: NSFileProviderServiceName("app.kernova.clipboard.test.relay.\(unique)"),
        reconnectNotificationName: "app.kernova.clipboard.test.reconnect.\(unique)",
        domainIdentifier: "kernova-clipboard-test",
        domainDisplayName: "Kernova Clipboard (Test)",
        containerDirectoryName: "FileProviderTest",
        loggerSubsystem: "app.kernova.test",
        extensionLoggerSubsystem: "app.kernova.test.fileprovider",
        ownerCodeSigningRequirement: nil,
        extensionCodeSigningRequirement: nil)
}

// MARK: - Socket pair

/// Two `VsockChannel`s connected by a started `socketpair(AF_UNIX, SOCK_STREAM)`.
func makeStartedChannelPair() throws -> (a: VsockChannel, b: VsockChannel) {
    var fds: [Int32] = [-1, -1]
    let rc = fds.withUnsafeMutableBufferPointer { buf in
        socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
    }
    guard rc == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    let a = VsockChannel(fileDescriptor: fds[0])
    let b = VsockChannel(fileDescriptor: fds[1])
    a.start()
    b.start()
    return (a, b)
}

// MARK: - File helpers

/// Every regular file anywhere under `directory` (recursive).
func materializedFiles(under directory: URL) -> [URL] {
    guard
        let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter {
        (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }
}

/// Polls `predicate` until it holds or `timeout` elapses.
func pollUntil(
    timeout: Duration = testWaitBackstop, _ predicate: @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !predicate() {
        if ContinuousClock.now >= deadline {
            throw StreamTestFailure("Condition not met within \(timeout)")
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - Staging sink doubles

/// A `StagingSink` that parks every `write` until the test allows it through,
/// wrapping a real staging sink so everything else (bytes on disk, commit,
/// abort) behaves exactly as in production.
///
/// The receiver's write lane holds a backlog only while an append is
/// outstanding, which a real staging file never does long enough to observe —
/// this makes that window as wide as a test needs, so the pipelining (#615) can
/// be asserted deterministically instead of by timing.
final class GatedSink: StagingSink, @unchecked Sendable {
    private let wrapped: ClipboardFileStaging.Sink
    private let condition = NSCondition()
    private var allowance = 0
    private var started = 0
    private var completed = 0
    /// Notified when a write parks and after each completed write, so tests
    /// wait event-driven.
    let gate = AsyncGate()

    var url: URL { wrapped.url }

    init(wrapping sink: ClipboardFileStaging.Sink) { wrapped = sink }

    /// Writes the receiver's write lane has entered — the last of them is
    /// parked in the gate whenever `startedWrites > completedWrites`, which
    /// pins the lane at a known point.
    var startedWrites: Int {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    /// Writes that have fully completed (bytes on disk, `writtenBytes`
    /// about to advance).
    var completedWrites: Int {
        condition.lock()
        defer { condition.unlock() }
        return completed
    }

    /// Lets `count` more parked (or future) writes through.
    func allow(_ count: Int) {
        condition.lock()
        allowance += count
        condition.broadcast()
        condition.unlock()
    }

    /// Lets every remaining write through.
    func allowAll() {
        condition.lock()
        allowance = .max
        condition.broadcast()
        condition.unlock()
    }

    func write(_ data: Data) throws {
        condition.lock()
        started += 1
        condition.unlock()
        gate.notify()
        condition.lock()
        while allowance == 0 { condition.wait() }
        if allowance != .max { allowance -= 1 }
        condition.unlock()
        try wrapped.write(data)
        condition.lock()
        completed += 1
        condition.unlock()
        gate.notify()
    }

    @discardableResult
    func commit() throws -> URL { try wrapped.commit() }

    func abort() { wrapped.abort() }
}

/// A `StagingSink` that silently discards its `droppingWrite`-th write
/// (1-based) — accepting the bytes without storing them, and without throwing.
///
/// Models the one corruption the end-to-end digest cannot catch: the digest is
/// taken over the bytes that *arrive*, so bytes lost between the receive lane
/// and the file leave both the size and SHA-256 checks satisfied.
final class SilentlyDroppingSink: StagingSink, @unchecked Sendable {
    private let wrapped: ClipboardFileStaging.Sink
    private let droppingWrite: Int
    private let lock = NSLock()
    private var attempts = 0

    var url: URL { wrapped.url }

    init(wrapping sink: ClipboardFileStaging.Sink, droppingWrite: Int) {
        wrapped = sink
        self.droppingWrite = droppingWrite
    }

    func write(_ data: Data) throws {
        let attempt = lock.withLock {
            attempts += 1
            return attempts
        }
        guard attempt != droppingWrite else { return }
        try wrapped.write(data)
    }

    @discardableResult
    func commit() throws -> URL { try wrapped.commit() }

    func abort() { wrapped.abort() }
}

/// A `StagingSink` that throws on its `failingWrite`-th write (1-based),
/// wrapping a real staging sink otherwise — models a volume that fails an
/// append mid-stream.
final class FailingSink: StagingSink, @unchecked Sendable {
    private let wrapped: ClipboardFileStaging.Sink
    private let failingWrite: Int
    private let lock = NSLock()
    private var attempts = 0

    var url: URL { wrapped.url }

    init(wrapping sink: ClipboardFileStaging.Sink, failingWrite: Int) {
        wrapped = sink
        self.failingWrite = failingWrite
    }

    func write(_ data: Data) throws {
        let attempt = lock.withLock {
            attempts += 1
            return attempts
        }
        guard attempt != failingWrite else {
            throw StreamTestFailure("Injected staging write failure on write \(attempt)")
        }
        try wrapped.write(data)
    }

    @discardableResult
    func commit() throws -> URL { try wrapped.commit() }

    func abort() { wrapped.abort() }
}

// MARK: - Collector

/// Gathers the completed representations and aborts a receiver delivers.
final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: [UInt64: ClipboardContent.Representation] = [:]
    private var aborts: [ClipboardStreamAbortInfo] = []
    private var timings: [ClipboardTransferMetrics] = []
    private var acks: [Kernova_V1_ClipboardStreamAck] = []
    let gate = AsyncGate()

    func complete(_ id: UInt64, _ representation: ClipboardContent.Representation) {
        lock.withLock { completed[id] = representation }
        gate.notify()
    }
    func abort(_ info: ClipboardStreamAbortInfo) {
        lock.withLock { aborts.append(info) }
        gate.notify()
    }
    func timed(_ metrics: ClipboardTransferMetrics) {
        lock.withLock { timings.append(metrics) }
        gate.notify()
    }
    func ack(_ ack: Kernova_V1_ClipboardStreamAck) {
        lock.withLock { acks.append(ack) }
        gate.notify()
    }

    var completedCount: Int { lock.withLock { completed.count } }
    func representation(_ id: UInt64) -> ClipboardContent.Representation? {
        lock.withLock { completed[id] }
    }
    var abortInfos: [ClipboardStreamAbortInfo] { lock.withLock { aborts } }
    var abortCount: Int { lock.withLock { aborts.count } }
    var timedMetrics: [ClipboardTransferMetrics] { lock.withLock { timings } }
    /// The `bytes_consumed` sequence of every recorded ack for one transfer.
    func ackedByteCounts(_ id: UInt64) -> [UInt64] {
        lock.withLock { acks.filter { $0.transferID == id }.map(\.bytesConsumed) }
    }
}

// MARK: - Harness

/// Wires a `ClipboardStreamSender` (channel A) and `ClipboardStreamReceiver`
/// (channel B) over a socketpair, with two routing tasks standing in for the
/// owning services: A's inbound acks/aborts feed the sender; B's inbound
/// begin/chunk/end/abort feed the receiver.
final class StreamHarness: @unchecked Sendable {
    let sender: ClipboardStreamSender
    let receiver: ClipboardStreamReceiver
    let staging: ClipboardFileStaging
    /// Parent of the staging root; tests scan it for materialized temp files.
    let stagingTempRoot: URL
    let collector = StreamCollector()

    private let a: VsockChannel
    private let b: VsockChannel
    private var routeTasks: [Task<Void, Never>] = []

    init(
        chunkSize: Int,
        windowBytes: Int,
        noAckTimeout: Duration = .seconds(10),
        ackLatencyBound: Duration = ClipboardStreamTuning.ackLatencyBound,
        stallTimeout: Duration = ClipboardStreamTuning.inboundStallTimeout,
        maxResidentInlineBytes: Int = ClipboardStreamTuning.maxResidentInlineBytes,
        suppressAcks: Bool = false,
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil,
        sinkFactory: ClipboardStreamReceiver.SinkFactory? = nil
    ) throws {
        (a, b) = try makeStartedChannelPair()
        stagingTempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        staging = ClipboardFileStaging(
            label: "harness-\(UUID().uuidString)",
            tempRoot: stagingTempRoot,
            freeSpaceProvider: freeSpaceProvider)
        sender = ClipboardStreamSender(
            channel: a, chunkSize: chunkSize, windowBytes: windowBytes, noAckTimeout: noAckTimeout)
        let collector = self.collector
        receiver = ClipboardStreamReceiver(
            channel: b, staging: staging, windowBytes: windowBytes,
            ackLatencyBound: ackLatencyBound, stallTimeout: stallTimeout,
            maxResidentInlineBytes: maxResidentInlineBytes,
            sinkFactory: sinkFactory,
            onTransferTimed: { metrics in collector.timed(metrics) },
            onComplete: { id, rep in collector.complete(id, rep) },
            onAbort: { info in collector.abort(info) })

        let sender = self.sender
        let receiver = self.receiver
        let a = self.a
        let b = self.b
        routeTasks.append(
            Task {
                do {
                    for try await frame in b.incoming {
                        switch frame.payload {
                        case .clipboardStreamBegin(let x): receiver.handleBegin(x)
                        case .clipboardChunk(let x): receiver.handleChunk(x)
                        case .clipboardStreamEnd(let x): receiver.handleEnd(x)
                        case .clipboardStreamAbort(let x): receiver.handleAbort(x)
                        default: break
                        }
                    }
                } catch {}
            })
        routeTasks.append(
            Task {
                do {
                    for try await frame in a.incoming {
                        switch frame.payload {
                        case .clipboardStreamAck(let x):
                            collector.ack(x)
                            if suppressAcks { break }  // model a peer that never acks
                            sender.handleAck(
                                transferID: x.transferID, bytesConsumed: x.bytesConsumed,
                                windowBytes: x.windowBytes)
                        case .clipboardStreamAbort(let x):
                            sender.handleAbort(transferID: x.transferID)
                        default: break
                        }
                    }
                } catch {}
            })
    }

    func tearDown() {
        routeTasks.forEach { $0.cancel() }
        a.close()
        b.close()
        staging.sweep()
    }
}
