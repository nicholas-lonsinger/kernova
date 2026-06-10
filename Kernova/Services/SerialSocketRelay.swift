import Darwin
import Foundation
import os

/// Host-side AF_UNIX relay that exposes a running VM's serial port to an
/// external terminal client (e.g. `socat -,raw,echo=0 UNIX-CONNECT:<path>` or
/// `nc -U <path>`).
///
/// Guest serial output is tee'd to a single connected client via
/// `forwardOutput(_:)` — called from the background serial readability handler
/// in `VMInstance` — and raw bytes the client sends are written straight into
/// the guest's serial input pipe. The relay is strictly best-effort: a slow,
/// absent, or vanished client never blocks or breaks the authoritative
/// `serial.log` path that owns the same output stream.
///
/// Single-client by design (serial-cable semantics): a second connection
/// supersedes the first, which is the least-surprising behavior when a stale
/// `socat`/`nc` session didn't clean up.
///
/// **Concurrency**: `@unchecked Sendable`. All file-descriptor state is guarded
/// by a single `NSLock`; the accept loop and the client read loop run on a
/// private serial `DispatchQueue` via `DispatchSourceRead`. `forwardOutput(_:)`
/// is therefore safe to call from the background GCD queue that drives serial
/// output, with no actor hop — mirroring `VsockChannel`'s lock-based model.
// RATIONALE: `@unchecked Sendable` with a manual `NSLock` (rather than
// `@MainActor` isolation) so `forwardOutput` is callable directly from the
// background serial readability handler with no MainActor hop. Same rationale
// as `VsockChannel`.
final class SerialSocketRelay: @unchecked Sendable {
    /// Filesystem path of the bound socket, for UI display. `nil` until
    /// `start()` binds successfully, and `nil` again after `stop()` or if the
    /// path was too long for `sockaddr_un.sun_path` (see `start()`).
    private(set) var socketPath: String?

    private let path: String
    /// Write end of the guest's serial input pipe.
    ///
    /// Client bytes are written here verbatim. The relay never closes this
    /// handle — the `Pipe` that owns it is managed by `VMInstance` and outlives
    /// the relay's teardown.
    private let guestInput: FileHandle
    private let label: String

    private let queue: DispatchQueue
    private let lock = NSLock()

    // All fields below are guarded by `lock`. An fd of `-1` means inactive;
    // the relay is re-startable (stop() → start()) so a hot-toggle off→on
    // re-binds the same instance rather than needing a fresh object.
    private var listenFd: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clientFd: Int32 = -1
    private var clientSource: DispatchSourceRead?

    private static let logger = Logger(subsystem: "app.kernova", category: "SerialSocketRelay")

    /// Process-wide `SIGPIPE` suppression so a write to a client whose read
    /// side has vanished surfaces as `EPIPE` from `write(2)` instead of killing
    /// the process.
    ///
    /// Belt-and-suspenders alongside the per-fd `SO_NOSIGPIPE` set on each
    /// socket — the same rationale documented in `VsockChannel`.
    private static let suppressSIGPIPEOnce: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    /// Largest AF_UNIX path that fits in `sockaddr_un.sun_path` (including the
    /// NUL terminator) — 104 on Darwin.
    private static let maxPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    init(path: String, guestInputWriteHandle: FileHandle, label: String) {
        self.path = path
        self.guestInput = guestInputWriteHandle
        self.label = label
        self.queue = DispatchQueue(label: "app.kernova.serial-relay")
        _ = Self.suppressSIGPIPEOnce
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Binds + listens on the AF_UNIX path and begins accepting a client.
    ///
    /// Idempotent. If the path can't fit `sockaddr_un.sun_path`, logs `.fault`
    /// and stays disabled (`socketPath` remains `nil`) — the VM is unaffected.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard listenFd < 0 else { return }

        let pathBytes = Array(path.utf8)
        guard pathBytes.count + 1 <= Self.maxPathLength else {
            Self.logger.fault(
                "Serial relay socket path too long (\(pathBytes.count + 1, privacy: .public) > \(Self.maxPathLength, privacy: .public)) for '\(self.label, privacy: .public)'; relay disabled: \(self.path, privacy: .public)"
            )
            return
        }

        // Clear any stale socket file left by a prior crash before binding.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Self.logger.error(
                "Serial relay socket() failed for '\(self.label, privacy: .public)': errno \(errno, privacy: .public)")
            return
        }

        Self.setNoSIGPIPE(fd)
        Self.setNonBlocking(fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &addr.sun_path) { rawPtr in
            rawPtr.withMemoryRebound(to: CChar.self, capacity: Self.maxPathLength) { dst in
                for i in 0..<pathBytes.count { dst[i] = CChar(bitPattern: pathBytes[i]) }
                dst[pathBytes.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Self.logger.error(
                "Serial relay bind() failed for '\(self.label, privacy: .public)': errno \(errno, privacy: .public)")
            close(fd)
            return
        }

        // Owner-only: only the same user may connect to the serial socket.
        chmod(path, mode_t(S_IRUSR | S_IWUSR))

        guard listen(fd, 1) == 0 else {
            Self.logger.error(
                "Serial relay listen() failed for '\(self.label, privacy: .public)': errno \(errno, privacy: .public)")
            close(fd)
            unlink(path)
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { close(fd) }
        listenFd = fd
        listenSource = source
        socketPath = path
        source.resume()

        Self.logger.notice(
            "Serial relay listening for '\(self.label, privacy: .public)' at \(self.path, privacy: .public)")
    }

    /// Closes the client + listener, cancels both dispatch sources, and unlinks
    /// the socket file.
    ///
    /// Idempotent.
    func stop() {
        lock.lock()
        defer { lock.unlock() }

        tearDownClientLocked()

        listenSource?.cancel()  // cancel handler closes listenFd
        listenSource = nil
        listenFd = -1

        if socketPath != nil {
            unlink(path)
            socketPath = nil
        }
        Self.logger.notice("Serial relay stopped for '\(self.label, privacy: .public)'")
    }

    // MARK: - Output tee (guest → client)

    /// Best-effort tee of guest serial output to the connected client.
    ///
    /// Safe to call from any thread (the background serial readability handler).
    /// Never blocks: a slow/full client drops the chunk (the `serial.log`
    /// already has it); a vanished client is torn down.
    func forwardOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard clientFd >= 0 else { return }

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(clientFd, base + offset, raw.count - offset)
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
                tearDownClientLocked()
                break
            }
        }
    }

    // MARK: - Accept / read (client → guest)

    private func acceptClient() {
        lock.lock()
        defer { lock.unlock() }
        guard listenFd >= 0 else { return }

        let newFd = accept(listenFd, nil, nil)
        guard newFd >= 0 else { return }  // EWOULDBLOCK / transient — source will refire

        Self.setNoSIGPIPE(newFd)
        Self.setNonBlocking(newFd)

        // Single-client semantics: supersede any existing client.
        if clientFd >= 0 {
            tearDownClientLocked()
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: newFd, queue: queue)
        source.setEventHandler { [weak self] in self?.readFromClient() }
        source.setCancelHandler { close(newFd) }
        clientFd = newFd
        clientSource = source
        source.resume()

        Self.logger.info("Serial relay client connected for '\(self.label, privacy: .public)'")
    }

    private func readFromClient() {
        lock.lock()
        guard clientFd >= 0 else {
            lock.unlock()
            return
        }

        // The client fd is non-blocking, so this read returns immediately.
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let n = buffer.withUnsafeMutableBytes { read(clientFd, $0.baseAddress, $0.count) }

        guard n > 0 else {
            let err = n < 0 ? errno : 0
            let wasEOF = n == 0
            // EOF or a fatal error drops the client (keeping the listener for
            // reconnects); EAGAIN/EWOULDBLOCK/EINTR are transient and ignored.
            if wasEOF || (err != EAGAIN && err != EWOULDBLOCK && err != EINTR) {
                tearDownClientLocked()
            }
            lock.unlock()
            if wasEOF {
                Self.logger.info("Serial relay client disconnected for '\(self.label, privacy: .public)'")
            }
            return
        }

        // Forward to the guest OUTSIDE the lock. `guestInput.write` is a blocking
        // pipe write that stalls if the guest stops draining its serial input;
        // holding `lock` across it would block `forwardOutput` (the output tee)
        // and a MainActor `stop()` / hot-toggle, hanging the app.
        let data = Data(buffer[0..<n])
        lock.unlock()
        do {
            try guestInput.write(contentsOf: data)
        } catch {
            Self.logger.error(
                "Serial relay failed to write client input to guest for '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Closes and forgets the current client.
    ///
    /// Must be called with `lock` held. The fd is closed by the read source's
    /// cancel handler, so `forwardOutput` (which guards on `clientFd >= 0` under
    /// the same lock) can never write to a recycled descriptor.
    private func tearDownClientLocked() {
        clientSource?.cancel()
        clientSource = nil
        clientFd = -1
    }

    #if DEBUG
    /// `true` once a client connection has been accepted (and not yet torn
    /// down).
    ///
    /// Lets tests await acceptance deterministically before exercising
    /// `forwardOutput`, which is otherwise a silent no-op until a client is
    /// attached.
    var hasClientForTesting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return clientFd >= 0
    }
    #endif

    // MARK: - Socket options

    private static func setNoSIGPIPE(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
}
