import CryptoKit
import Foundation
import Darwin
import KernovaKit
import KernovaTestSupport

// Bundle-specific test helpers for KernovaMacOSAgentTests. The event-driven/
// poll wait primitives (`AsyncGate`, `waitUntil`, `TestFailure`) and the
// ephemeral-`UserDefaults` helpers (`makeEphemeralDefaults`,
// `withEphemeralDefaults`) live in the shared `KernovaTestSupport` package
// product — see its doc comments for why they were hoisted out of this file
// (formerly triplicated, #526; the ephemeral-defaults helpers followed in
// #581 for `AgentPreferencesTests`, mirroring `KernovaTests`' identically-
// shaped `AppPreferencesTests`).

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

// MARK: - nextFrame

/// Reads the next frame from `channel`, distinguishing timeout from EOF.
///
/// - Throws: `TestFailure("Timed out…")` when no frame arrives within `timeout`.
/// - Throws: `TestFailure("Channel finished…")` when the channel closes without
///   producing a frame (EOF), so the two failure shapes are identifiable.
func nextFrame(
    from channel: VsockChannel,
    timeout: Duration = .seconds(5)
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
    timeout: Duration = .seconds(5)
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
///
/// Exposes a `changed` gate so tests can `await changed.wait { value >= n }`
/// instead of polling — each `increment()` fires the gate.
final class AtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Int = 0

    /// Fires on every `increment()`; await it instead of polling `value`.
    let changed = AsyncGate()

    @discardableResult
    func increment() -> Int {
        let newValue = lock.withLock { () -> Int in
            storedValue += 1
            return storedValue
        }
        changed.notify()
        return newValue
    }

    var value: Int {
        lock.withLock { storedValue }
    }
}

// MARK: - Streaming frame factories

/// One representation's metadata as it rides in a `ClipboardOffer.repInfo`.
///
/// Mirrors `Kernova_V1_ClipboardRepresentationInfo` so tests can describe an
/// offer declaratively. `byteCount` defaults to the UTI's text length only as a
/// convenience for inline reps; callers stream the real bytes separately.
struct RepInfo {
    var uti: String
    var byteCount: UInt64
    var filename: String
    var isInline: Bool
    var isDirectory: Bool

    init(
        uti: String, byteCount: UInt64, filename: String = "", isInline: Bool,
        isDirectory: Bool = false
    ) {
        self.uti = uti
        self.byteCount = byteCount
        self.filename = filename
        self.isInline = isInline
        self.isDirectory = isDirectory
    }

    /// A single inline text representation (`public.utf8-plain-text`).
    static func text(_ string: String) -> RepInfo {
        RepInfo(
            uti: ClipboardContent.utf8TextUTI, byteCount: UInt64(Data(string.utf8).count),
            isInline: true)
    }
}

/// Metadata-only offer carrying one `repInfo` entry per representation.
///
/// The host announces what it has; the agent eager-pulls each rep with a
/// `ClipboardRequest`. No bytes ride in the offer.
func makeOfferFrame(generation: UInt64, reps: [RepInfo]) -> Frame {
    var frame = Frame()
    frame.protocolVersion = 1
    frame.clipboardOffer = Kernova_V1_ClipboardOffer.with {
        $0.generation = generation
        $0.repInfo = reps.map { rep in
            Kernova_V1_ClipboardRepresentationInfo.with {
                $0.uti = rep.uti
                $0.byteCount = rep.byteCount
                $0.filename = rep.filename
                $0.isInline = rep.isInline
                $0.isDirectory = rep.isDirectory
            }
        }
    }
    return frame
}

/// Convenience: an offer for a single inline text representation.
func makeTextOfferFrame(generation: UInt64, text: String) -> Frame {
    makeOfferFrame(generation: generation, reps: [.text(text)])
}

/// A `ClipboardRequest` pulling one representation of a generation.
func makeRequestFrame(
    generation: UInt64, transferID: UInt64, uti: String, maxAcceptByteCount: UInt64 = .max
) -> Frame {
    var frame = Frame()
    frame.protocolVersion = 1
    frame.clipboardRequest = Kernova_V1_ClipboardRequest.with {
        $0.generation = generation
        $0.transferID = transferID
        $0.uti = uti
        $0.maxAcceptByteCount = maxAcceptByteCount
    }
    return frame
}

/// A `ClipboardStreamBegin` opening an inbound transfer to the agent.
func makeBeginFrame(
    generation: UInt64, transferID: UInt64, uti: String, totalBytes: Int, filename: String = "",
    isInline: Bool
) -> Frame {
    var frame = Frame()
    frame.protocolVersion = 1
    frame.clipboardStreamBegin = Kernova_V1_ClipboardStreamBegin.with {
        $0.generation = generation
        $0.transferID = transferID
        $0.uti = uti
        $0.totalBytes = UInt64(totalBytes)
        $0.filename = filename
        $0.isInline = isInline
    }
    return frame
}

/// A `ClipboardChunk` carrying `data` at `offset` for a transfer.
func makeChunkFrame(transferID: UInt64, offset: Int, data: Data) -> Frame {
    var frame = Frame()
    frame.protocolVersion = 1
    frame.clipboardChunk = Kernova_V1_ClipboardChunk.with {
        $0.transferID = transferID
        $0.offset = UInt64(offset)
        $0.data = data
    }
    return frame
}

/// A `ClipboardStreamEnd` closing a transfer, with the real SHA-256 over
/// `payload` so the agent's receiver verifies and commits.
func makeEndFrame(transferID: UInt64, payload: Data) -> Frame {
    var frame = Frame()
    frame.protocolVersion = 1
    frame.clipboardStreamEnd = Kernova_V1_ClipboardStreamEnd.with {
        $0.transferID = transferID
        $0.totalBytes = UInt64(payload.count)
        $0.sha256 = Data(SHA256.hash(data: payload))
    }
    return frame
}

/// A `ClipboardStreamAbort` failing an inbound transfer the agent is receiving
/// (we are the host sender aborting a lazy pull mid-flight).
func makeAbortFrame(transferID: UInt64, code: String, message: String) -> Frame {
    var frame = Frame()
    frame.protocolVersion = 1
    frame.clipboardStreamAbort = Kernova_V1_ClipboardStreamAbort.with {
        $0.transferID = transferID
        $0.code = code
        $0.message = message
    }
    return frame
}

/// A `ClipboardStreamAck` releasing/crediting an outbound transfer the agent is
/// sending. `windowBytes` defaults to a generous window so the whole payload can
/// flow without further acks; `bytesConsumed` is cumulative.
func makeAckFrame(
    transferID: UInt64, bytesConsumed: Int = 0, windowBytes: Int = 512 * 1024
) -> Frame {
    var frame = Frame()
    frame.protocolVersion = 1
    frame.clipboardStreamAck = Kernova_V1_ClipboardStreamAck.with {
        $0.transferID = transferID
        $0.bytesConsumed = UInt64(bytesConsumed)
        $0.windowBytes = UInt64(windowBytes)
    }
    return frame
}

// MARK: - Host-side stream driver

/// Collects the `Begin`/`Chunk`(s)/`End` of one outbound transfer the agent
/// sends in reply to a `ClipboardRequest`, returning the reassembled bytes and
/// the transfer's metadata.
///
/// The agent's `ClipboardStreamSender` waits for a first ack (the go-signal)
/// before chunking, so the caller must send `makeAckFrame(...)` *after* the
/// `ClipboardRequest` to release it. This driver reads frames until `End`,
/// re-acking each chunk so a small test window can't stall the transfer.
struct CollectedTransfer {
    var begin: Kernova_V1_ClipboardStreamBegin
    var bytes: Data
    var end: Kernova_V1_ClipboardStreamEnd
}

/// Reads `Begin`→`Chunk`(s)→`End` for `transferID` off `channel`, acking as it
/// goes.
///
/// Sends the go-signal ack itself, on receipt of `Begin` — mirroring the real
/// receiver, which acks in response to `Begin`. (The caller must not pre-send an
/// ack: the agent's consume loop processes stream frames off-main, so an ack
/// sent before the `ClipboardRequest` is handled could overtake it and be
/// dropped before the transfer is registered.)
func collectOutboundTransfer(
    transferID: UInt64, from channel: VsockChannel, timeout: Duration = .seconds(5)
) async throws -> CollectedTransfer {
    var begin: Kernova_V1_ClipboardStreamBegin?
    var assembled = Data()

    while true {
        let frame = try await nextFrame(from: channel, timeout: timeout)
        switch frame.payload {
        case .clipboardStreamBegin(let b) where b.transferID == transferID:
            begin = b
            // Go-signal: release the sender now that Begin has arrived.
            try channel.send(makeAckFrame(transferID: transferID, bytesConsumed: 0))
        case .clipboardChunk(let c) where c.transferID == transferID:
            assembled.append(c.data)
            // Re-ack cumulative progress so a small window keeps advancing.
            try channel.send(
                makeAckFrame(transferID: transferID, bytesConsumed: assembled.count))
        case .clipboardStreamEnd(let e) where e.transferID == transferID:
            guard let begin else {
                throw TestFailure("Got End for transfer \(transferID) before Begin")
            }
            return CollectedTransfer(begin: begin, bytes: assembled, end: e)
        case .clipboardStreamAbort(let a) where a.transferID == transferID:
            throw TestFailure(
                "Outbound transfer \(transferID) aborted: \(a.code) — \(a.message)")
        default:
            // A frame for another transfer/payload — keep reading.
            continue
        }
    }
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
