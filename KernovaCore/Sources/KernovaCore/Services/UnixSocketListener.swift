import Foundation
import KernovaKit
import Synchronization

/// An `AF_UNIX` stream socket the app binds, listens on, and accepts clients
/// from — the plumbing every host-side listener shares.
///
/// It owns the socket and nothing above it: what an accepted connection means
/// belongs to the handler `start(onAccept:)` takes, which is called on `queue`
/// with the listener's own lock released, so a caller may take its own lock
/// inside the callback without inverting the two.
///
/// The accepted descriptor is the callback's to own — it arrives with
/// `SO_NOSIGPIPE` and `O_NONBLOCK` already set, and nothing here closes it.
final class UnixSocketListener: Sendable {
    /// Why `start()` could not bring the socket up.
    enum StartFailure: Error, Equatable {
        /// The path does not fit `sockaddr_un.sun_path`.
        case address(UnixSocketAddress.Failure)
        case socket(errno: Int32)
        case bind(errno: Int32)
        case listen(errno: Int32)
    }

    /// Filesystem path of the bound socket — `nil` until `start()` binds
    /// successfully, and again after `stop()`.
    var boundPath: String? {
        state.withLock { $0.bound }
    }

    private let path: String
    private let queue: DispatchQueue
    private let backlog: Int32
    private let fileMode: mode_t

    /// The listener is re-startable — stop() then start() re-binds the same
    /// instance.
    private struct State {
        /// `-1` means inactive.
        var listenFd: Int32 = -1
        var listenSource: DispatchSourceRead?
        var bound: String?
        var onAccept: (@Sendable (Int32) -> Void)?
    }

    private let state = Mutex(State())

    /// Process-wide `SIGPIPE` suppression so a write to a peer whose read side
    /// has vanished surfaces as `EPIPE` from `write(2)` instead of killing the
    /// process.
    private static let suppressSIGPIPEOnce: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    /// Prepares a listener for `path`, which nothing binds until `start()`.
    ///
    /// `fileMode` is applied to the socket file after bind.
    init(path: String, queue: DispatchQueue, backlog: Int32, fileMode: mode_t) {
        self.path = path
        self.queue = queue
        self.backlog = backlog
        self.fileMode = fileMode
        _ = Self.suppressSIGPIPEOnce
    }

    deinit {
        stop()
    }

    /// Binds and listens on the path, then begins handing accepted descriptors
    /// to `onAccept`.
    ///
    /// The handler is taken here rather than at init so the owner can name
    /// itself in it — a listener with nowhere to deliver has nothing to do
    /// until it is started. Idempotent: a second call on a bound listener does
    /// nothing, handler included. A stale socket file from a prior crash is
    /// unlinked first.
    func start(onAccept: @escaping @Sendable (Int32) -> Void) throws(StartFailure) {
        try state.withLock { state throws(StartFailure) in
            try start(onAccept: onAccept, in: &state)
        }
    }

    private func start(
        onAccept: @escaping @Sendable (Int32) -> Void, in state: inout State
    ) throws(StartFailure) {
        guard state.listenFd < 0 else { return }

        var address = try Self.address(for: path)

        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .socket(errno: errno) }

        Self.setNoSIGPIPE(fd)
        Self.setNonBlocking(fd)

        let bindResult = UnixSocketAddress.withSockaddr(&address) { socketAddress, length in
            bind(fd, socketAddress, length)
        }
        guard bindResult == 0 else {
            let code = errno
            close(fd)
            throw .bind(errno: code)
        }

        chmod(path, fileMode)

        guard listen(fd, backlog) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw .listen(errno: code)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(fd) }
        state.listenFd = fd
        state.listenSource = source
        state.bound = path
        state.onAccept = onAccept
        source.resume()
    }

    /// Cancels the accept source, closes the listening socket, and unlinks the
    /// socket file.
    ///
    /// Idempotent. Connections already handed to `onAccept` are untouched.
    func stop() {
        state.withLock { state in
            state.listenSource?.cancel()  // cancel handler closes listenFd
            state.listenSource = nil
            state.listenFd = -1
            state.onAccept = nil

            if state.bound != nil {
                unlink(path)
                state.bound = nil
            }
        }
    }

    private static func address(for path: String) throws(StartFailure) -> sockaddr_un {
        do {
            return try UnixSocketAddress.make(path: path)
        } catch {
            throw .address(error)
        }
    }

    private func acceptOne() {
        let next: (fd: Int32, deliver: @Sendable (Int32) -> Void)? = state.withLock { state in
            guard state.listenFd >= 0, let deliver = state.onAccept else { return nil }
            // The listening fd is non-blocking, so this returns immediately.
            return (accept(state.listenFd, nil, nil), deliver)
        }
        guard let (accepted, deliver) = next else { return }
        guard accepted >= 0 else { return }  // EWOULDBLOCK / transient — the source refires

        Self.setNoSIGPIPE(accepted)
        Self.setNonBlocking(accepted)
        deliver(accepted)
    }

    // MARK: - Socket options

    static func setNoSIGPIPE(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
}
