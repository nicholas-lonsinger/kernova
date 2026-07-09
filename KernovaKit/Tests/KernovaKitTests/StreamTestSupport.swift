import Darwin
import FileProvider
import Foundation

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

// MARK: - AsyncGate (package-test copy)

/// Resumes its continuation at most once across the `notify()`/timeout race.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire(_ body: () -> Void) {
        lock.lock()
        let already = fired
        fired = true
        lock.unlock()
        if !already { body() }
    }
}

/// Event-driven wait primitive — a producer calls `notify()` after each state
/// change; the consumer awaits `wait(until:)`.
///
/// Mirrors the app/guest test
/// bundles' `AsyncGate` (kept in sync per the flaky-CI investigation), copied
/// here because Xcode synchronized folders make those copies target-private.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: () -> Void] = [:]

    func notify() {
        lock.lock()
        let resumes = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        resumes.forEach { $0() }
    }

    func wait(
        timeout: Duration = .seconds(10),
        until predicate: @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate() {
            if ContinuousClock.now >= deadline {
                throw StreamTestFailure("Condition not met within \(timeout)")
            }
            await armOnce(deadline: deadline, predicate: predicate)
        }
    }

    private func armOnce(
        deadline: ContinuousClock.Instant,
        predicate: @Sendable () -> Bool
    ) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let id = UUID()
            let once = ResumeOnce()
            lock.lock()
            waiters[id] = { once.fire { cont.resume() } }
            lock.unlock()
            if predicate() {
                lock.withLock { _ = waiters.removeValue(forKey: id) }
                once.fire { cont.resume() }
                return
            }
            Task {
                try? await Task.sleep(until: deadline, clock: ContinuousClock())
                self.lock.withLock { _ = self.waiters.removeValue(forKey: id) }
                once.fire { cont.resume() }
            }
        }
    }
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
    timeout: Duration = .seconds(5), _ predicate: @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !predicate() {
        if ContinuousClock.now >= deadline {
            throw StreamTestFailure("Condition not met within \(timeout)")
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - Collector

/// Gathers the completed representations and aborts a receiver delivers.
final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: [UInt64: ClipboardContent.Representation] = [:]
    private var aborts: [ClipboardStreamAbortInfo] = []
    let gate = AsyncGate()

    func complete(_ id: UInt64, _ representation: ClipboardContent.Representation) {
        lock.withLock { completed[id] = representation }
        gate.notify()
    }
    func abort(_ info: ClipboardStreamAbortInfo) {
        lock.withLock { aborts.append(info) }
        gate.notify()
    }

    var completedCount: Int { lock.withLock { completed.count } }
    func representation(_ id: UInt64) -> ClipboardContent.Representation? {
        lock.withLock { completed[id] }
    }
    var abortInfos: [ClipboardStreamAbortInfo] { lock.withLock { aborts } }
    var abortCount: Int { lock.withLock { aborts.count } }
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
        stallTimeout: Duration = ClipboardStreamTuning.inboundStallTimeout,
        maxResidentInlineBytes: Int = ClipboardStreamTuning.maxResidentInlineBytes,
        suppressAcks: Bool = false,
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil
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
            channel: b, staging: staging, windowBytes: windowBytes, stallTimeout: stallTimeout,
            maxResidentInlineBytes: maxResidentInlineBytes,
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
