import Foundation
import Darwin
import KernovaProtocol

// MARK: - TestFailure

struct TestFailure: Error {
    let message: String
    init(_ m: String) { message = m }
}

// MARK: - Socket / channel factories

/// Returns a connected AF_UNIX socketpair as two raw file descriptors.
func makeRawSocketPair() throws -> (Int32, Int32) {
    var fds: [Int32] = [-1, -1]
    let rc = fds.withUnsafeMutableBufferPointer { buf in
        socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
    }
    guard rc == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    return (fds[0], fds[1])
}

/// Returns a started, connected channel pair backed by a socketpair.
func makeChannelPair() throws -> (VsockChannel, VsockChannel) {
    let (fd0, fd1) = try makeRawSocketPair()
    let a = VsockChannel(fileDescriptor: fd0)
    let b = VsockChannel(fileDescriptor: fd1)
    a.start()
    b.start()
    return (a, b)
}

// MARK: - waitUntil

/// Polls `predicate` every 10 ms until it returns `true` or `timeout` elapses.
func waitUntil(
    timeout: Duration = .seconds(2),
    _ predicate: @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !predicate() && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard predicate() else {
        throw TestFailure("Predicate did not become true within \(timeout)")
    }
}

// MARK: - nextFrame

/// Reads the next frame from `channel`, distinguishing timeout from EOF.
///
/// - Throws: `TestFailure("Timed out…")` when no frame arrives within `timeout`.
/// - Throws: `TestFailure("Channel finished…")` when the channel closes without
///   producing a frame (EOF), so the two failure shapes are identifiable.
func nextFrame(
    from channel: VsockChannel,
    timeout: Duration = .seconds(2)
) async throws -> Frame {
    let receiver = Task<Frame?, Error> {
        var iterator = channel.incoming.makeAsyncIterator()
        return try await iterator.next()
    }
    let timeoutTask = Task<Void, Never> {
        try? await Task.sleep(for: timeout)
        receiver.cancel()
    }
    defer { timeoutTask.cancel() }

    do {
        guard let frame = try await receiver.value else {
            throw TestFailure("Channel finished without producing a frame (EOF)")
        }
        return frame
    } catch is CancellationError {
        throw TestFailure("Timed out waiting for a frame after \(timeout)")
    }
}

// MARK: - awaitFirst

/// Awaits the first value emitted by `stream`, with a timeout.
///
/// - Throws: `TestFailure("Timed out…")` if no value arrives within `timeout`.
func awaitFirst<T: Sendable>(
    _ stream: AsyncStream<T>,
    timeout: Duration = .seconds(2)
) async throws -> T {
    let task = Task<T?, Never> {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
    let timeoutTask = Task<Void, Never> {
        try? await Task.sleep(for: timeout)
        task.cancel()
    }
    defer { timeoutTask.cancel() }
    guard let value = await task.value else {
        throw TestFailure("Timed out waiting for stream value after \(timeout)")
    }
    return value
}

// MARK: - AtomicInt

/// Lock-protected integer for use in non-async closures (e.g. socket providers).
final class AtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            _value += 1
            return _value
        }
    }

    var value: Int {
        lock.withLock { _value }
    }
}

// MARK: - Frame factories

func makeHelloFrame() -> Frame {
    var frame = Frame()
    frame.protocolVersion = 1
    frame.hello = Kernova_V1_Hello.with {
        $0.serviceVersion = 1
        $0.capabilities = ["clipboard.text.utf8"]
    }
    return frame
}

func makeOfferFrame(generation: UInt64) -> Frame {
    var frame = Frame()
    frame.protocolVersion = 1
    frame.clipboardOffer = Kernova_V1_ClipboardOffer.with {
        $0.generation = generation
        $0.formats = [.textUtf8]
    }
    return frame
}

func makeDataFrame(generation: UInt64, text: String) -> Frame {
    var frame = Frame()
    frame.protocolVersion = 1
    frame.clipboardData = Kernova_V1_ClipboardData.with {
        $0.generation = generation
        $0.format = .textUtf8
        $0.data = Data(text.utf8)
    }
    return frame
}

func makeRequestFrame(generation: UInt64) -> Frame {
    var frame = Frame()
    frame.protocolVersion = 1
    frame.clipboardRequest = Kernova_V1_ClipboardRequest.with {
        $0.generation = generation
        $0.format = .textUtf8
    }
    return frame
}

func makeLogFrame(message: String) -> Frame {
    var frame = Frame()
    frame.protocolVersion = 1
    frame.logRecord = Kernova_V1_LogRecord.with {
        $0.timestampMs = 0
        $0.level = .info
        $0.subsystem = "test"
        $0.category = "test"
        $0.message = message
    }
    return frame
}
