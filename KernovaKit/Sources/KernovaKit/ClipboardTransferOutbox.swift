import Foundation

/// The transfers this side is serving, one data connection each.
///
/// Owner logic — which requests are answered and which are refused — lives
/// above this; the outbox turns a verdict into a connection, keeps the live
/// transfers reachable for supersession, and forgets each one as it ends.
public final class ClipboardTransferOutbox: @unchecked Sendable {
    private let role: ClipboardDataConnection.Role
    private let clock: any EngineClock
    private let socketTimeout: TimeInterval
    private let maxResidentInlineBytes: Int
    private let onTransferTimed: (@Sendable (ClipboardTransferMetrics) -> Void)?

    private let lock = NSLock()
    private var live: [UInt64: ClipboardTransferSender] = [:]

    /// Where a refusal's own blocking dial and write run, off whatever actor
    /// decided it.
    private let refusals = DispatchQueue(
        label: "app.kernova.clipboard.transfer-refuse", qos: .userInitiated,
        attributes: .concurrent)

    /// Creates an outbox for one peer.
    ///
    /// - Parameters:
    ///   - role: which end of a data connection this side holds.
    ///   - clock: the timeline stage timings are measured on.
    ///   - socketTimeout: each connection's `SO_RCVTIMEO`/`SO_SNDTIMEO`.
    ///   - maxResidentInlineBytes: the largest inline payload streamed raw.
    ///   - onTransferTimed: fired once per successful transfer.
    public init(
        role: ClipboardDataConnection.Role,
        clock: any EngineClock = makePlatformEngineClock(),
        socketTimeout: TimeInterval = ClipboardStreamTuning.dataSocketTimeout,
        maxResidentInlineBytes: Int = ClipboardStreamTuning.maxResidentInlineBytes,
        onTransferTimed: (@Sendable (ClipboardTransferMetrics) -> Void)? = nil
    ) {
        self.role = role
        self.clock = clock
        self.socketTimeout = socketTimeout
        self.maxResidentInlineBytes = maxResidentInlineBytes
        self.onTransferTimed = onTransferTimed
    }

    /// Streams `representation` to the peer over `link`.
    ///
    /// A duplicate `transferID` never displaces the transfer already streaming
    /// under it: the second `link` is abandoned — its accepted descriptor
    /// closed, its dialler never called — and `onComplete` does not fire for it,
    /// since the id's own transfer is still running and owes its owner that one
    /// terminal.
    ///
    /// - Parameters:
    ///   - transferID: identifies the transfer, and keys it for cancellation.
    ///   - generation: the offer generation the representation belongs to.
    ///   - representation: what to stream.
    ///   - maxAcceptByteCount: the requester's payload ceiling.
    ///   - isInline: whether the receiver delivers the payload as pasteboard
    ///     bytes.
    ///   - isCurrent: supersession check, called off the caller's actor.
    ///   - link: how the connection is obtained.
    ///   - onProgress: cumulative `(bytesSent, totalBytes)` as bytes leave.
    ///   - onComplete: fired exactly once when the transfer ends.
    public func serve(
        transferID: UInt64,
        generation: UInt64,
        representation: ClipboardContent.Representation,
        maxAcceptByteCount: UInt64,
        isInline: Bool,
        isCurrent: @escaping @Sendable (UInt64) -> Bool,
        link: ClipboardTransferLink,
        onProgress: (@Sendable (_ bytesSent: Int, _ totalBytes: Int) -> Void)? = nil,
        onComplete: (@Sendable (_ success: Bool) -> Void)? = nil
    ) {
        let sender = ClipboardTransferSender(
            transferID: transferID, generation: generation, link: link, role: role, clock: clock,
            socketTimeout: socketTimeout, maxResidentInlineBytes: maxResidentInlineBytes,
            onTransferTimed: onTransferTimed)
        let inserted = lock.withLock { () -> Bool in
            guard live[transferID] == nil else { return false }
            live[transferID] = sender
            return true
        }
        guard inserted else {
            link.abandon()
            return
        }
        sender.start(
            representation: representation, maxAcceptByteCount: maxAcceptByteCount,
            isInline: isInline, isCurrent: isCurrent, onProgress: onProgress
        ) { [weak self] success in
            self?.forget(transferID)
            onComplete?(success)
        }
    }

    /// Answers a request this side will not serve: a reply naming `code`, no
    /// payload, and the connection closed.
    ///
    /// The dial and the write both block, so they run off the caller's actor.
    /// No transfer is ever registered — the request is refused before one
    /// exists.
    public func refuse(
        link: ClipboardTransferLink, transferID: UInt64, code: ClipboardStreamAbortCode,
        message: String
    ) {
        let role = self.role
        let socketTimeout = self.socketTimeout
        refusals.async {
            let fd: Int32
            switch link {
            case .accepted(let accepted):
                fd = accepted
            case .dial(let dial):
                guard let dialled = try? dial() else { return }
                fd = dialled
            }
            ClipboardDataConnection.applySocketOptions(fd: fd, role: role, timeout: socketTimeout)
            defer { ClipboardDataConnection.end(fd: fd) }
            try? ClipboardDataConnection.writeFrame(
                .clipboardTransferRefusal(transferID: transferID, code: code, message: message),
                fd: fd)
        }
    }

    /// Retires every in-flight transfer of a superseded offer generation, so
    /// each one's trailer tells the peer why its bytes stopped.
    public func cancel(generation: UInt64) {
        let affected = lock.withLock { live.values.filter { $0.generation == generation } }
        for sender in affected { sender.cancel(.superseded) }
    }

    /// Retires one in-flight transfer, naming `code` in its trailer.
    public func cancel(transferID: UInt64, code: ClipboardStreamAbortCode) {
        lock.withLock { live[transferID] }?.cancel(code)
    }

    /// Retires every in-flight transfer — a channel teardown or a capability
    /// going away.
    public func cancelAll() {
        let all = lock.withLock { Array(live.values) }
        for sender in all { sender.cancel(.cancelled) }
    }

    private func forget(_ transferID: UInt64) {
        lock.withLock { live[transferID] = nil }
    }
}
