import Darwin
import Foundation
import KernovaKit
import os

/// The app's command socket: an `AF_UNIX` listener in the app-group container
/// carrying length-prefixed `VMCommandRequest`/`VMCommandResponse` frames.
///
/// The out-of-process twin of the App Intents front door — same verbs, same
/// refusals, same consent semantics, because both reach ``VMCommanding``
/// through ``VMCommandEnvelopeRouter`` and neither adds a vocabulary of its
/// own.
///
/// A build with no group container to bind in, or no team to authorize peers
/// against, publishes no socket and logs why: the capability is absent rather
/// than present and broken.
@MainActor
final class VMCommandSocketListener: AutomationWorkCounting {
    /// Owner-only on the socket file, so the group container's own rules are
    /// not the only thing standing between a stranger and the socket.
    private static let socketFileMode = mode_t(S_IRUSR | S_IWUSR)

    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "VMCommandSocketListener")

    private let router: VMCommandEnvelopeRouter
    private let authorizer: (any PeerAuthorizing)?
    private let socketPath: String?
    private let awaitReady: @MainActor @Sendable () async -> Void
    private let onIdle: @MainActor () -> Void
    private let queue = DispatchQueue(label: "app.kernova.command-socket")

    private var listener: UnixSocketListener?
    private var connections: [ObjectIdentifier: VMCommandConnection] = [:]

    /// `true` while any client is connected — what holds an automation launch
    /// open until the last one leaves.
    var hasWorkInFlight: Bool { !connections.isEmpty }

    /// Prepares the socket, which nothing binds until `start()`.
    ///
    /// A `nil` `socketPath` or `authorizer` is the degraded build: `start()`
    /// binds nothing and says so once.
    ///
    /// `awaitReady` is the app's first library read. The socket is bound before
    /// that read lands — deliberately, so a client that just launched the app
    /// finds something to connect to — which means a verb answered eagerly
    /// would report an empty library as the truth. Every request waits on it.
    init(
        router: VMCommandEnvelopeRouter,
        authorizer: (any PeerAuthorizing)?,
        socketPath: String?,
        awaitReady: @MainActor @Sendable @escaping () async -> Void,
        onIdle: @MainActor @escaping () -> Void
    ) {
        self.router = router
        self.authorizer = authorizer
        self.socketPath = socketPath
        self.awaitReady = awaitReady
        self.onIdle = onIdle
    }

    /// Binds the socket and begins accepting same-team clients.
    func start() {
        guard let socketPath else {
            Self.logger.warning(
                "No app-group container resolved — the command socket is unavailable in this build")
            return
        }
        guard let authorizer else {
            Self.logger.warning(
                "No peer authorizer for this build's signature — the command socket stays closed")
            return
        }
        guard listener == nil else { return }

        let listener = UnixSocketListener(
            path: socketPath, queue: queue, backlog: 8, fileMode: Self.socketFileMode)
        let router = self.router
        let awaitReady = self.awaitReady
        do {
            try listener.start { [weak self] fd in
                Self.admit(
                    fd, authorizer: authorizer, router: router, awaitReady: awaitReady,
                    queue: self?.queue
                ) {
                    connection in
                    Task { @MainActor [weak self] in
                        guard let self else {
                            connection.close()
                            return
                        }
                        self.adopt(connection)
                    }
                }
            }
        } catch {
            Self.logger.error(
                "The command socket could not bind at \(socketPath, privacy: .public) — \(String(describing: error), privacy: .public)"
            )
            return
        }
        self.listener = listener
        // Two copies of the app signed by the same team share this path, and
        // the second to bind wins after unlinking the first's socket file.
        Self.logger.notice(
            "Listening for VM commands at \(socketPath, privacy: .public)")
    }

    /// Unbinds the socket and closes every live connection.
    func stop() {
        listener?.stop()
        listener = nil
        let live = connections.values
        connections.removeAll()
        for connection in live { connection.close() }
    }

    // MARK: - Connections

    private func adopt(_ connection: VMCommandConnection) {
        guard listener != nil else {
            connection.close()
            return
        }
        connections[ObjectIdentifier(connection)] = connection
        connection.start { [weak self] in
            Task { @MainActor [weak self] in
                self?.forget(connection)
            }
        }
    }

    private func forget(_ connection: VMCommandConnection) {
        guard connections.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return }
        onIdle()
    }

    // MARK: - Accept

    /// Authorizes one accepted descriptor, then hands the caller a connection
    /// for it. Runs on the socket queue, off the main actor.
    ///
    /// A peer that fails the check is told so in one frame and disconnected —
    /// a silent close is indistinguishable from a crash, and a client cannot
    /// map that to an exit code.
    nonisolated private static func admit(
        _ fd: Int32,
        authorizer: any PeerAuthorizing,
        router: VMCommandEnvelopeRouter,
        awaitReady: @MainActor @Sendable @escaping () async -> Void,
        queue: DispatchQueue?,
        adopt: (VMCommandConnection) -> Void
    ) {
        guard let queue else {
            Darwin.close(fd)
            return
        }
        guard let token = peerAuditToken(of: fd) else {
            refuse(
                fd, router: router,
                reason: "The connecting process could not be identified.")
            return
        }
        guard authorizer.isAuthorized(peer: token) else {
            refuse(
                fd, router: router,
                reason: "Only Kernova components signed by the same team may drive this app.")
            return
        }
        adopt(VMCommandConnection(fd: fd, queue: queue, router: router, awaitReady: awaitReady))
    }

    /// Writes one refusal frame, best-effort, and closes the descriptor.
    nonisolated private static func refuse(
        _ fd: Int32, router: VMCommandEnvelopeRouter, reason: String
    ) {
        Self.logger.notice(
            "Refused a connection on the command socket: \(reason, privacy: .public)")
        let payload = router.encode(
            VMCommandResponse(result: .refused(.authorizationRefused(reason: reason))))
        if let framed = try? StreamFrame.encode(payload) {
            framed.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                _ = write(fd, base, raw.count)
            }
        }
        Darwin.close(fd)
    }

    /// The audit token of the process on the other end, `nil` when the kernel
    /// will not name it.
    nonisolated private static func peerAuditToken(of fd: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        let result = withUnsafeMutablePointer(to: &token) { pointer in
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, pointer, &length)
        }
        guard result == 0, length == socklen_t(MemoryLayout<audit_token_t>.size) else { return nil }
        return token
    }
}

/// One client on the command socket, from accept to close.
///
/// Every field is touched on the listener's private queue and nowhere else;
/// `send(_:)`, `close()` and `follow(_:)` are the three entry points a
/// main-actor caller uses, and each hops to that queue before touching
/// anything. The main actor is reached only to run a verb — parsing and
/// serialization stay off it.
final class VMCommandConnection: @unchecked Sendable {
    /// How long a connection may stay silent before it is closed.
    ///
    /// A client that connects and never speaks costs a descriptor and holds an
    /// automation launch open; nothing legitimate waits this long before its
    /// first frame.
    private static let firstFrameTimeout: DispatchTimeInterval = .seconds(30)

    /// Ceiling on the bytes buffered for a client that has stopped reading.
    /// Reaching it means the peer is gone or wedged, and the connection goes.
    private static let maxPendingWriteBytes = 8 * 1024 * 1024

    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "VMCommandConnection")

    private let fd: Int32
    private let queue: DispatchQueue
    private let router: VMCommandEnvelopeRouter
    private let awaitReady: @MainActor @Sendable () async -> Void

    private var decoder = StreamFrameDecoder()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var timeoutSource: DispatchSourceTimer?
    private var pendingWrite = Data()
    private var subscription: Task<Void, Never>?
    private var onClose: (@Sendable () -> Void)?
    private var isClosed = false

    init(
        fd: Int32,
        queue: DispatchQueue,
        router: VMCommandEnvelopeRouter,
        awaitReady: @MainActor @Sendable @escaping () async -> Void
    ) {
        self.fd = fd
        self.queue = queue
        self.router = router
        self.awaitReady = awaitReady
    }

    /// Begins reading, and arms the silent-client deadline.
    func start(onClose: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard !isClosed else {
                onClose()
                return
            }
            self.onClose = onClose

            let descriptor = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.setCancelHandler { Darwin.close(descriptor) }
            readSource = source

            let deadline = DispatchSource.makeTimerSource(queue: queue)
            deadline.schedule(deadline: .now() + Self.firstFrameTimeout)
            deadline.setEventHandler { [weak self] in
                Self.logger.notice("Closing a command connection that sent no frame in time")
                self?.closeNow()
            }
            timeoutSource = deadline

            source.resume()
            deadline.resume()
        }
    }

    /// Queues one response payload, framed, for the client.
    func send(_ payload: Data) {
        queue.async { [self] in
            guard !isClosed else { return }
            guard let framed = try? StreamFrame.encode(payload) else {
                Self.logger.error("A response was too large to frame; closing the connection")
                closeNow()
                return
            }
            pendingWrite.append(framed)
            guard pendingWrite.count <= Self.maxPendingWriteBytes else {
                Self.logger.notice(
                    "A client stopped reading with \(self.pendingWrite.count, privacy: .public) bytes owed; closing the connection"
                )
                closeNow()
                return
            }
            flushPending()
        }
    }

    /// Adopts the task pumping an event subscription, so closing cancels it.
    func follow(_ task: Task<Void, Never>) {
        queue.async { [self] in
            guard !isClosed else {
                task.cancel()
                return
            }
            subscription?.cancel()
            subscription = task
        }
    }

    /// Closes the connection; safe from any isolation, idempotent.
    func close() {
        queue.async { [self] in closeNow() }
    }

    // MARK: - Read

    private func readAvailable() {
        guard !isClosed else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }

        guard count > 0 else {
            if count == 0 {
                closeNow()  // EOF
                return
            }
            let code = errno
            if code != EAGAIN && code != EWOULDBLOCK && code != EINTR { closeNow() }
            return
        }

        decoder.feed(Data(buffer[0..<count]))
        drainFrames()
    }

    private func drainFrames() {
        while !isClosed {
            let payload: Data?
            do {
                payload = try decoder.nextFrame()
            } catch {
                Self.logger.notice(
                    "A client framed a request this build will not buffer; closing the connection")
                closeNow()
                return
            }
            guard let payload else { return }
            timeoutSource?.cancel()
            timeoutSource = nil
            answer(Data(payload))
        }
    }

    /// Answers one request frame.
    ///
    /// Parsing and serialization run here, on the socket queue; only the verb
    /// itself crosses to the main actor.
    private func answer(_ data: Data) {
        switch router.decode(data) {
        case .failure(let refusal):
            // The envelope is unreadable, so nothing later on this stream can
            // be trusted either: answer, then hang up.
            send(router.encode(VMCommandResponse(result: .refused(refusal))))
            close()
        case .success(let request):
            let router = self.router
            let awaitReady = self.awaitReady
            if case .events = request.verb {
                Task { @MainActor [self] in
                    await awaitReady()
                    let (snapshot, events) = router.snapshotAndEvents()
                    send(router.encode(snapshot))
                    follow(
                        Task { [self] in
                            for await event in events {
                                send(router.encode(event))
                            }
                        })
                }
            } else {
                Task { @MainActor [self] in
                    // The library read has to have landed: a verb run against a
                    // library that has not is not refused, it is answered wrong.
                    await awaitReady()
                    send(router.encode(await router.respond(to: request)))
                }
            }
        }
    }

    // MARK: - Write

    private func flushPending() {
        while !pendingWrite.isEmpty {
            let written = pendingWrite.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return write(fd, base, raw.count)
            }
            if written > 0 {
                pendingWrite.removeFirst(written)
                continue
            }
            let code = errno
            if code == EINTR { continue }
            if code == EAGAIN || code == EWOULDBLOCK {
                armWriteSource()
                return
            }
            closeNow()  // EPIPE or worse: the client is gone
            return
        }
        writeSource?.cancel()
        writeSource = nil
    }

    /// Waits for the socket to drain, then resumes the flush.
    ///
    /// Created on demand and cancelled once drained rather than kept
    /// suspended, so there is no resume/suspend balance to get wrong. It sets
    /// no cancel handler: the read source's is the one that closes the shared
    /// descriptor.
    private func armWriteSource() {
        guard writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, !self.isClosed else { return }
            self.flushPending()
        }
        writeSource = source
        source.resume()
    }

    // MARK: - Close

    private func closeNow() {
        guard !isClosed else { return }
        isClosed = true

        timeoutSource?.cancel()
        timeoutSource = nil
        writeSource?.cancel()
        writeSource = nil
        subscription?.cancel()
        subscription = nil
        pendingWrite = Data()

        if let readSource {
            readSource.cancel()  // the cancel handler closes the descriptor
            self.readSource = nil
        } else {
            Darwin.close(fd)  // closed before `start()` armed the source
        }

        let notify = onClose
        onClose = nil
        notify?()
    }
}
