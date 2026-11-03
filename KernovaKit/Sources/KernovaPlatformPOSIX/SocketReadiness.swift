#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// Apple's Dispatch marks `DispatchQueue` `Sendable`; swift-corelibs-libdispatch does not, though dispatch
// objects are thread-safe on every platform.
#if canImport(Darwin)
import Dispatch
#else
@preconcurrency import Dispatch
#endif
import KernovaAgentRuntime
import KernovaSynchronization

// Not dispatch read and write sources: swift-corelibs-libdispatch's epoll backend (Swift 6.4.1,
// `src/event/event_epoll.c`, `_dispatch_event_merge_fd`) acts on `EPOLLIN`, `EPOLLOUT` and `EPOLLHUP` and
// never on `EPOLLERR`. A socket with an error pending and nothing to read — a Linux vsock after its transport
// resets, as `virtio_vsock_reset_sock` sets only `sk_err` — never fires a read source, and the backend
// re-arms the descriptor at once, so its manager thread holds a core until the source is cancelled.

/// Waits for sockets to turn readable or writable on one thread for the process, in `poll(2)`, and hands
/// each readiness to its registration's queue. An error or hang-up pending on a socket makes every armed
/// direction ready, so the call the handler makes reports it.
public final class SocketReadiness: Sendable {
    /// The directions a registration waits for.
    public struct Directions: OptionSet, Sendable {
        /// The directions' bits.
        public let rawValue: UInt8
        /// The directions whose bits `rawValue` holds.
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// Readable, at end of file, or failed.
        public static let read = Directions(rawValue: 1)
        /// Writable, or failed.
        public static let write = Directions(rawValue: 2)
    }

    /// One descriptor's place in the wait.
    public final class Registration: Sendable {
        private let readiness: SocketReadiness
        fileprivate let id: Int

        fileprivate init(readiness: SocketReadiness, id: Int) {
            self.readiness = readiness
            self.id = id
        }

        /// Waits once for `directions`: the handler runs once a direction is ready and the waiting for it ends,
        /// so each wait follows a call that found the socket not ready. Any thread; nothing after `cancel`.
        public func arm(_ directions: Directions) {
            readiness.arm(id, directions)
        }

        /// Ends the wait. `then` runs on the registration's queue once the waiting thread no longer polls the
        /// descriptor, after every handler call already queued, so it may close the descriptor. Once, any thread.
        public func cancel(then: @escaping @Sendable () -> Void) {
            readiness.cancel(id, then: then)
        }
    }

    private struct Entry {
        let descriptor: Int32
        let queue: DispatchQueue
        let ready: @Sendable (Directions) -> Void
        var armed: Directions = []
        var cancelled: (@Sendable () -> Void)?
    }

    private struct State {
        var entries: [Int: Entry] = [:]
        var nextID = 0
        /// A byte sits in the wake pipe, or the thread has yet to snapshot the entries.
        var wakePending = false
    }

    private static let process = Locked<SocketReadiness?>(nil)

    private let state = Locked(State())
    /// The wake pipe's read and write ends, both non-blocking and close-on-exec.
    private let wakeRead: Int32
    private let wakeWrite: Int32

    /// The process's readiness thread, started on first use. Throws the OS's error when the wake pipe or the
    /// thread cannot be made; a later call tries again.
    public static func shared() throws(ByteStreamError) -> SocketReadiness {
        try process.withLock { (shared: inout SocketReadiness?) throws(ByteStreamError) -> SocketReadiness in
            if let shared { return shared }
            let made = try SocketReadiness()
            shared = made
            return made
        }
    }

    private init() throws(ByteStreamError) {
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { throw .system(errno) }
        for end in ends {
            let flags = fcntl(end, F_GETFL)
            let descriptorFlags = fcntl(end, F_GETFD)
            guard flags >= 0, fcntl(end, F_SETFL, flags | O_NONBLOCK) == 0, descriptorFlags >= 0,
                fcntl(end, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
            else {
                let error = errno
                close(ends[0])
                close(ends[1])
                throw .system(error)
            }
        }
        wakeRead = ends[0]
        wakeWrite = ends[1]
        let started = ReadinessThread.start(Unmanaged.passRetained(self))
        guard started == 0 else {
            close(wakeRead)
            close(wakeWrite)
            throw .system(started)
        }
    }

    /// Registers `descriptor`, waiting for nothing until `arm`. `ready` runs on `queue` with the directions
    /// that turned ready.
    public func register(
        _ descriptor: Int32, queue: DispatchQueue, ready: @escaping @Sendable (Directions) -> Void
    ) -> Registration {
        let id = state.withLock { state -> Int in
            defer { state.nextID += 1 }
            state.entries[state.nextID] = Entry(descriptor: descriptor, queue: queue, ready: ready)
            return state.nextID
        }
        return Registration(readiness: self, id: id)
    }

    private func arm(_ id: Int, _ directions: Directions) {
        let wake = state.withLock { state -> Bool in
            guard var entry = state.entries[id], entry.cancelled == nil else { return false }
            guard !entry.armed.isSuperset(of: directions) else { return false }
            entry.armed.formUnion(directions)
            state.entries[id] = entry
            return Self.claimWake(&state)
        }
        if wake { signal() }
    }

    private func cancel(_ id: Int, then: @escaping @Sendable () -> Void) {
        let wake = state.withLock { state -> Bool in
            guard var entry = state.entries[id], entry.cancelled == nil else {
                preconditionFailure("a registration cancelled twice")
            }
            entry.cancelled = then
            entry.armed = []
            state.entries[id] = entry
            return Self.claimWake(&state)
        }
        if wake { signal() }
    }

    private static func claimWake(_ state: inout State) -> Bool {
        guard !state.wakePending else { return false }
        state.wakePending = true
        return true
    }

    private func signal() {
        var byte: UInt8 = 0
        // A full pipe already holds a wake.
        _ = write(wakeWrite, &byte, 1)
    }

    // MARK: The waiting thread

    /// Never returns. Each pass drops what was cancelled, polls what is armed, and disarms and hands on what
    /// turned ready.
    fileprivate func run() -> Never {
        var drain = [UInt8](repeating: 0, count: 64)
        while true {
            // Emptied before the snapshot, so a wake claimed after it leaves its byte for the poll below.
            while drain.withUnsafeMutableBytes({ read(wakeRead, $0.baseAddress, $0.count) }) > 0 {}
            let (polled, released) = state.withLock { state -> ([(Int, pollfd)], [Released]) in
                state.wakePending = false
                var released: [Released] = []
                var polled: [(Int, pollfd)] = []
                for (id, entry) in state.entries {
                    if let then = entry.cancelled {
                        state.entries[id] = nil
                        released.append(Released(queue: entry.queue, then: then))
                    } else if !entry.armed.isEmpty {
                        polled.append((id, pollfd(fd: entry.descriptor, events: Self.events(entry.armed), revents: 0)))
                    }
                }
                return (polled, released)
            }
            for item in released { item.queue.async(execute: item.then) }

            var descriptors = [pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)] + polled.map(\.1)
            guard poll(&descriptors, nfds_t(descriptors.count), -1) > 0 else {
                let error = errno
                // Every descriptor is open and counted by the process's limit, so only a signal or a
                // momentary shortage of kernel memory fails the call.
                guard error == EINTR || error == EAGAIN || error == ENOMEM else {
                    preconditionFailure("poll failed with errno \(error)")
                }
                continue
            }

            let fired = state.withLock { state -> [Fired] in
                var fired: [Fired] = []
                for (index, (id, _)) in polled.enumerated() {
                    let revents = descriptors[index + 1].revents
                    guard revents != 0, var entry = state.entries[id], entry.cancelled == nil else { continue }
                    let ready = entry.armed.intersection(Self.directions(revents))
                    guard !ready.isEmpty else { continue }
                    entry.armed.subtract(ready)
                    state.entries[id] = entry
                    fired.append(Fired(queue: entry.queue, ready: entry.ready, directions: ready))
                }
                return fired
            }
            for item in fired { item.queue.async { item.ready(item.directions) } }
        }
    }

    private struct Released {
        let queue: DispatchQueue
        let then: @Sendable () -> Void
    }

    private struct Fired {
        let queue: DispatchQueue
        let ready: @Sendable (Directions) -> Void
        let directions: Directions
    }

    private static func events(_ directions: Directions) -> Int16 {
        var events: Int32 = 0
        if directions.contains(.read) { events |= Int32(POLLIN) }
        if directions.contains(.write) { events |= Int32(POLLOUT) }
        return Int16(events)
    }

    /// `POLLERR`, `POLLHUP` and `POLLNVAL` are reported whatever was asked for, and make both directions ready.
    private static func directions(_ revents: Int16) -> Directions {
        let revents = Int32(revents)
        let failed = revents & Int32(POLLERR | POLLHUP | POLLNVAL) != 0
        var directions: Directions = []
        if failed || revents & Int32(POLLIN) != 0 { directions.insert(.read) }
        if failed || revents & Int32(POLLOUT) != 0 { directions.insert(.write) }
        return directions
    }
}

/// The detached thread `SocketReadiness.run()` holds for the life of the process.
private enum ReadinessThread {
    /// Starts it, handing it the retained readiness; the error number `pthread_create` returned.
    static func start(_ readiness: Unmanaged<SocketReadiness>) -> Int32 {
        // Darwin and Musl import `pthread_t` as a pointer, Glibc as an integer; Darwin's start routine takes a
        // non-optional context.
        #if canImport(Glibc)
        var thread = pthread_t()
        #else
        var thread: pthread_t?
        #endif
        #if canImport(Darwin)
        let created = pthread_create(
            &thread, nil, { Unmanaged<SocketReadiness>.fromOpaque($0).takeRetainedValue().run() },
            readiness.toOpaque())
        #else
        let created = pthread_create(
            &thread, nil,
            { context in
                guard let context else { preconditionFailure("the readiness thread started without its context") }
                Unmanaged<SocketReadiness>.fromOpaque(context).takeRetainedValue().run()
            }, readiness.toOpaque())
        #endif
        guard created == 0 else {
            readiness.release()
            return created
        }
        #if canImport(Glibc)
        pthread_detach(thread)
        #else
        if let thread { pthread_detach(thread) }
        #endif
        return 0
    }
}
#endif
