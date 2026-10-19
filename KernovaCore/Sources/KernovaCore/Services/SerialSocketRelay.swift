import Foundation
import KernovaLogging
import Synchronization

/// Host-side AF_UNIX relay that exposes a running VM's serial port to an
/// external terminal client (e.g. `socat -,raw,echo=0 UNIX-CONNECT:<path>`).
///
/// Strictly best-effort: a slow, absent, or vanished client never blocks or
/// breaks the authoritative `serial.log` path that owns the same output stream.
/// Single-client — a second connection supersedes the first. All client
/// file-descriptor state is guarded by one `Mutex`, so `forwardOutput(_:)` is
/// safe to call from the background queue that drives serial output; the socket
/// itself belongs to a ``UnixSocketListener``.
final class SerialSocketRelay: Sendable {
    /// Filesystem path of the bound socket, for UI display — `nil` until
    /// `start()` binds successfully, and again after `stop()`.
    var socketPath: String? { listener.boundPath }

    private let path: String
    /// Write end of the guest's serial input pipe.
    ///
    /// The relay never closes this handle — `VMInstance` owns the `Pipe`, which
    /// outlives the relay's teardown.
    private let guestInput: FileHandle
    private let label: String

    private let queue: DispatchQueue
    private let client = Mutex(Client())
    private let listener: UnixSocketListener

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "SerialSocketRelay")

    init(path: String, guestInputWriteHandle: FileHandle, label: String) {
        let queue = DispatchQueue(label: "app.kernova.serial-relay")
        self.path = path
        self.guestInput = guestInputWriteHandle
        self.label = label
        self.queue = queue
        // Owner-only: only the same user may connect to the serial socket.
        self.listener = UnixSocketListener(
            path: path, queue: queue, backlog: 1, fileMode: mode_t(S_IRUSR | S_IWUSR))
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Binds + listens on the AF_UNIX path and begins accepting a client.
    ///
    /// Idempotent. A path that can't fit `sockaddr_un.sun_path`, or a socket the
    /// app cannot bind, leaves the relay disabled (`socketPath` stays `nil`) —
    /// the VM is unaffected.
    func start() {
        do {
            try listener.start { [weak self] fd in self?.adoptClient(fd) }
        } catch .address(let failure) {
            // A path the app derived itself, so one that does not fit is a bug
            // in how it was derived rather than a condition to recover from.
            Self.logger.log(
                .fault,
                "Serial relay socket path unusable for '\(self.label, privacy: .public)' — \(String(describing: failure), privacy: .public): \(self.path, privacy: .public)"
            )
            return
        } catch {
            Self.logger.log(
                .error,
                "Serial relay could not bind for '\(self.label, privacy: .public)' — \(String(describing: error), privacy: .public): \(self.path, privacy: .public)"
            )
            return
        }
        Self.logger.log(
            .notice,
            "Serial relay listening for '\(self.label, privacy: .public)' at \(self.path, privacy: .public)")
    }

    /// Closes the client, stops the listener, and unlinks the socket file.
    ///
    /// Idempotent.
    func stop() {
        client.withLock { $0.tearDown() }

        listener.stop()
        Self.logger.log(.notice, "Serial relay stopped for '\(self.label, privacy: .public)'")
    }

    // MARK: - Output tee (guest → client)

    /// Best-effort tee of guest serial output to the connected client.
    ///
    /// Safe to call from any thread (the background serial readability handler).
    /// Never blocks: a slow/full client drops the chunk (the `serial.log`
    /// already has it); a vanished client is torn down.
    func forwardOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        client.withLock { client in
            guard client.fd >= 0 else { return }

            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let n = write(client.fd, base + offset, raw.count - offset)
                    if n > 0 {
                        offset += n
                        continue
                    }
                    let err = errno
                    if err == EINTR { continue }
                    if err == EAGAIN || err == EWOULDBLOCK {
                        // Client buffer full — drop the remainder rather than stall
                        // the serial reader.
                        break
                    }
                    // EPIPE or other fatal write error: the client is gone.
                    client.tearDown()
                    break
                }
            }
        }
    }

    // MARK: - Accept / read (client → guest)

    /// Takes ownership of a newly accepted connection, superseding any client
    /// already on the wire.
    private func adoptClient(_ newFd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: newFd, queue: queue)
        source.setEventHandler { [weak self] in self?.readFromClient() }
        source.setCancelHandler { close(newFd) }
        client.withLock { client in
            // Single-client semantics: supersede any existing client.
            client.tearDown()
            client.fd = newFd
            client.source = source
            source.resume()
        }

        Self.logger.log(.info, "Serial relay client connected for '\(self.label, privacy: .public)'")
    }

    private func readFromClient() {
        let outcome: ClientRead = client.withLock { client in
            guard client.fd >= 0 else { return .nothing }

            // The client fd is non-blocking, so this read returns immediately.
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let n = buffer.withUnsafeMutableBytes { read(client.fd, $0.baseAddress, $0.count) }

            guard n > 0 else {
                let err = n < 0 ? errno : 0
                let wasEOF = n == 0
                // EOF or a fatal error drops the client (keeping the listener for
                // reconnects); EAGAIN/EWOULDBLOCK/EINTR are transient and ignored.
                if wasEOF || (err != EAGAIN && err != EWOULDBLOCK && err != EINTR) {
                    client.tearDown()
                }
                return wasEOF ? .disconnected : .nothing
            }
            return .input(Data(buffer[0..<n]))
        }

        // Forward to the guest OUTSIDE the lock. `guestInput.write` is a blocking
        // pipe write that stalls if the guest stops draining its serial input;
        // holding `client`'s lock across it would block `forwardOutput` and a
        // MainActor `stop()`, hanging the app.
        let data: Data
        switch outcome {
        case .nothing:
            return
        case .disconnected:
            Self.logger.log(.info, "Serial relay client disconnected for '\(self.label, privacy: .public)'")
            return
        case .input(let input):
            data = input
        }
        do {
            try guestInput.write(contentsOf: data)
        } catch {
            Self.logger.log(
                .error,
                "Serial relay failed to write client input to guest for '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// What one readable event on the client produced.
    private enum ClientRead {
        case nothing
        case disconnected
        case input(Data)
    }

    private struct Client {
        /// `-1` means no client.
        var fd: Int32 = -1
        var source: DispatchSourceRead?

        /// Closes and forgets the current client.
        ///
        /// The fd is closed by the read source's cancel handler, so
        /// `forwardOutput` can never write to a recycled descriptor.
        mutating func tearDown() {
            source?.cancel()
            source = nil
            fd = -1
        }
    }

    #if DEBUG
    /// `true` once a client connection has been accepted and not yet torn down.
    var hasClientForTesting: Bool {
        client.withLock { $0.fd >= 0 }
    }
    #endif
}
