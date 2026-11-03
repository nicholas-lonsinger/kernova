#if os(macOS)
import Darwin
import Foundation
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaLogging
import KernovaSynchronization

/// Why a vsock connect to the host did not complete: `.transient` is worth retrying, `.permanent` never is.
public enum VsockConnectFailure: Error, Sendable, Equatable {
    /// Retry-able: the host not listening yet, transient kernel resource pressure.
    case transient(String)
    /// Not retry-able: the kernel has no `AF_VSOCK` support.
    case permanent(String)
}

/// A macOS guest's vsock connect to the host, bounded on every macOS the agent supports.
///
/// macOS 26+ uses the non-blocking-plus-poll idiom, while every floor below runs a blocking `connect(2)` on a
/// throwaway thread the caller can walk away from. Monterey's virtio-vsock never completes a non-blocking
/// connect (docs/research/2026-08-02-macos12-vsock-nonblocking-connect.md), and macOS 13 and 14 complete it
/// while leaving the socket state-blind — poll, kqueue, and `SO_RCVTIMEO`/`SO_SNDTIMEO` all misbehave on the fd
/// (docs/research/2026-08-06-macos13-vsock-nonblocking-state-blind.md,
/// docs/research/2026-08-06-macos14-vsock-state-blind.md) — so the split sits at the oldest OS the
/// non-blocking idiom is proven on. A socket that reached the connected state through the blocking connect
/// behaves normally (docs/research/2026-08-08-macos13-14-vsock-blocking-socket-timeouts.md).
public enum DarwinVsockConnect {
    private static let logger = KernovaLogger(subsystem: "app.kernova.macosagent", category: "VsockConnect")

    /// Ceiling on one connect attempt. vsock is local-only with no SYN dance: a connect is normally immediate
    /// success or immediate `ECONNREFUSED`, so 3 s is a generous ceiling.
    public static let connectTimeoutSeconds: Int = 3

    /// Opens an `AF_VSOCK / SOCK_STREAM` socket and connects it to the host's `port`, in blocking mode;
    /// `label` names the attempt in the log and keeps its parked-connect budget in `gate` apart from other
    /// labels'.
    public static func connect(
        port: UInt32, label: String, gate: BlockingConnectGate = .process
    ) -> Result<Int32, VsockConnectFailure> {
        let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(classifySocketErrno(errno, label: label)) }

        var addr = sockaddr_vm()
        // Darwin's `sockaddr` family carries a leading `sa_len`/`svm_len` byte the networking stack may rely on;
        // set it even though some paths infer it.
        addr.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        addr.svm_family = sa_family_t(AF_VSOCK)
        addr.svm_port = port
        addr.svm_cid = UInt32(VMADDR_CID_HOST)

        if #available(macOS 26.0, *) {
            guard connectNonBlocking(fd: fd, addr: addr, label: label, port: port) else {
                close(fd)
                return .failure(.transient("connect() to '\(label)' port \(port) did not complete"))
            }
            return .success(fd)
        }
        switch connectBlocking(fd: fd, addr: addr, label: label, port: port, gate: gate) {
        case .connected:
            return .success(fd)
        case .failed(let err):
            close(fd)
            logger.log(
                .warning,
                "connect() to '\(label, privacy: .public)' port \(port, privacy: .public) failed: errno=\(err, privacy: .public)"
            )
            return .failure(.transient("connect() to '\(label)' port \(port) failed: errno=\(err)"))
        case .abandoned:
            // The worker owns `fd` and closes it when the kernel returns.
            return .failure(.transient("connect() to '\(label)' port \(port) outran \(connectTimeoutSeconds)s"))
        case .busy:
            close(fd)
            logger.log(
                .warning,
                "connect() to '\(label, privacy: .public)' port \(port, privacy: .public) held back: earlier attempts are parked with none completing since; the gate admits the next one after its backoff"
            )
            return .failure(.transient("connect() to '\(label)' port \(port) is gated behind parked earlier attempts"))
        }
    }

    /// Classifies a `socket(AF_VSOCK)` errno as permanent or transient: `EAFNOSUPPORT` and `EPROTONOSUPPORT`
    /// mean the kernel has no `AF_VSOCK` support and will never succeed; everything else may clear up.
    public static func classifySocketErrno(_ err: Int32, label: String) -> VsockConnectFailure {
        switch err {
        case EAFNOSUPPORT, EPROTONOSUPPORT:
            logger.log(
                .error,
                "socket(AF_VSOCK) unsupported for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return .permanent("socket(AF_VSOCK) unsupported for '\(label)': errno=\(err)")
        default:
            logger.log(
                .warning,
                "socket(AF_VSOCK) failed for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return .transient("socket(AF_VSOCK) failed for '\(label)': errno=\(err)")
        }
    }

    /// What a bounded blocking `connect(2)` did.
    public enum BlockingConnectOutcome: Equatable, Sendable {
        case connected
        case failed(errno: Int32)
        /// The deadline passed with the syscall still in the kernel. The worker thread owns `fd` and closes it
        /// when the call returns — the caller must not.
        case abandoned
        /// The gate refused the attempt; no socket was used.
        case busy
    }

    private static func connectBlocking(
        fd: Int32, addr: sockaddr_vm, label: String, port: UInt32, gate: BlockingConnectGate
    ) -> BlockingConnectOutcome {
        boundedBlockingConnect(fd: fd, label: label, port: port, gate: gate) {
            var addrCopy = addr
            let rc = withUnsafePointer(to: &addrCopy) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_vm>.size))
                }
            }
            return rc == 0 ? 0 : errno
        }
    }

    /// Runs `connectCall` — a blocking `connect(2)` returning `0` or its `errno` — on a thread the caller can
    /// walk away from, bounded at `deadline` seconds.
    ///
    /// Darwin bounds `connect(2)` with no socket option — `SO_SNDTIMEO` covers only `send` — and a vsock connect
    /// does park indefinitely when the host stops accepting
    /// (docs/research/2026-08-02-macos12-vsock-blocking-connect-parks.md), which on the caller's own thread
    /// strands it for the life of the process. Abandoning a thread rather than closing its socket keeps fd
    /// ownership unambiguous: nothing is closed while a syscall still holds it.
    public static func boundedBlockingConnect(
        fd: Int32, label: String, port: UInt32, gate: BlockingConnectGate = .process,
        deadline: TimeInterval = TimeInterval(connectTimeoutSeconds),
        connectCall: @escaping @Sendable () -> Int32
    ) -> BlockingConnectOutcome {
        guard gate.admit(label) else { return .busy }

        let handoff = BlockingConnectHandoff()
        let ready = DispatchSemaphore(value: 0)
        let worker = Thread {
            let waiterPresent = handoff.finish(errno: connectCall())
            if waiterPresent {
                gate.markCompleted(label)
                ready.signal()
            } else {
                gate.markParkReturned(label)
                close(fd)
            }
        }
        worker.name = "app.kernova.macosagent.vsock-connect"
        worker.start()

        if ready.wait(timeout: .now() + deadline) == .success, let err = handoff.outcome {
            return err == 0 ? .connected : .failed(errno: err)
        }
        gate.markParked(label)
        if handoff.abandon() {
            logger.log(
                .warning,
                "connect() to '\(label, privacy: .public)' port \(port, privacy: .public) still blocked after \(deadline, privacy: .public)s — abandoning it"
            )
            return .abandoned
        }
        gate.revertPark(label)
        // The syscall landed between the deadline expiring and the abandon: the worker saw the waiter present
        // and skipped its close, so the caller owns `fd` on every arm below — the fallback must never say
        // otherwise.
        guard let err = handoff.outcome else {
            logger.log(
                .fault, "connect() handoff for '\(label, privacy: .public)' settled with no outcome recorded")
            assertionFailure("connect() handoff for '\(label)' settled with no outcome recorded")
            return .failed(errno: EINVAL)
        }
        return err == 0 ? .connected : .failed(errno: err)
    }

    /// Connects `fd` in non-blocking mode with the connect-plus-poll idiom, then restores blocking mode. The
    /// caller owns `fd` on both paths and must `close()` it on a `false` return. The availability matches the
    /// split in `connect`: this idiom is proven only on macOS 26+.
    @available(macOS 26.0, *)
    private static func connectNonBlocking(fd: Int32, addr: sockaddr_vm, label: String, port: UInt32) -> Bool {
        let originalFlags = fcntl(fd, F_GETFL, 0)
        guard originalFlags >= 0 else {
            let err = errno
            logger.log(
                .error, "fcntl(F_GETFL) failed for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return false
        }
        guard fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) >= 0 else {
            let err = errno
            logger.log(
                .error,
                "fcntl(F_SETFL, O_NONBLOCK) failed for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return false
        }

        var addrCopy = addr
        let rc = withUnsafePointer(to: &addrCopy) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        if rc != 0 {
            let connectErr = errno
            guard connectErr == EINPROGRESS else {
                logger.log(
                    .warning,
                    "connect() to '\(label, privacy: .public)' port \(port, privacy: .public) failed: errno=\(connectErr, privacy: .public)"
                )
                return false
            }
            guard awaitConnectCompletion(fd: fd, label: label, port: port) else { return false }
        }

        guard fcntl(fd, F_SETFL, originalFlags) >= 0 else {
            let err = errno
            logger.log(
                .error,
                "fcntl(F_SETFL) restore failed for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return false
        }
        return true
    }

    /// Waits up to `connectTimeoutSeconds` for an in-flight non-blocking connect to complete on `fd`. The
    /// caller owns `fd` on both paths and must `close()` it on a `false` return.
    @available(macOS 26.0, *)
    private static func awaitConnectCompletion(fd: Int32, label: String, port: UInt32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let deadline = SystemScheduler().now.advanced(by: .seconds(Int64(connectTimeoutSeconds)))

        var pollRc: Int32
        repeat {
            let now = SystemScheduler().now
            let remainingMs = now < deadline ? Int32((deadline.nanoseconds - now.nanoseconds) / 1_000_000) : 0
            pollRc = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, remainingMs) }
            let err = errno
            if pollRc < 0 && err != EINTR {
                logger.log(
                    .warning,
                    "poll() while connecting '\(label, privacy: .public)' failed: errno=\(err, privacy: .public)")
                return false
            }
        } while pollRc < 0

        if pollRc == 0 {
            logger.log(
                .warning,
                "connect() to '\(label, privacy: .public)' port \(port, privacy: .public) timed out after \(connectTimeoutSeconds, privacy: .public)s"
            )
            return false
        }

        // POLLHUP is not a verdict here: with SO_ERROR reading 0 the connect itself completed, and a peer that
        // hung up right after accepting surfaces as EOF on the first read and rides the normal reconnect path.
        // The SO_ERROR check below is the sole authority; only the structural flags are fatal on sight.
        let fatalRevents = Int16(POLLERR) | Int16(POLLNVAL)
        if pfd.revents & fatalRevents != 0 {
            var soError: Int32 = 0
            var soErrorLen = socklen_t(MemoryLayout<Int32>.size)
            let errStr =
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soErrorLen) == 0 && soError != 0
                ? "errno=\(soError)" : "revents=\(pfd.revents)"
            logger.log(
                .warning,
                "connect() to '\(label, privacy: .public)' port \(port, privacy: .public) failed: \(errStr, privacy: .public)"
            )
            return false
        }

        var soError: Int32 = 0
        var soErrorLen = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soErrorLen) == 0 else {
            let err = errno
            logger.log(
                .warning,
                "getsockopt(SO_ERROR) for '\(label, privacy: .public)' failed: errno=\(err, privacy: .public)")
            return false
        }
        guard soError == 0 else {
            logger.log(
                .warning,
                "connect() to '\(label, privacy: .public)' port \(port, privacy: .public) failed (deferred): errno=\(soError, privacy: .public)"
            )
            return false
        }
        return true
    }
}

/// Carries the result of a blocking `connect(2)` back to a waiter that may have already given up, and settles
/// which side owns the socket when the deadline and the syscall land together.
///
/// Exactly one of `finish` and `abandon` sees the other as unfinished, so the fd has exactly one owner and is
/// never closed while the call is still in flight.
public final class BlockingConnectHandoff: Sendable {
    private struct State: Sendable {
        var recorded: Int32?
        var abandoned = false
    }

    private let state = Locked(State())

    public init() {}

    /// Records the syscall's `errno` (`0` on success): `true` while the waiter is still there — it takes the
    /// socket; `false` once the waiter has abandoned the attempt, leaving the caller holding the socket.
    public func finish(errno: Int32) -> Bool {
        state.withLock { state in
            state.recorded = errno
            return !state.abandoned
        }
    }

    /// Gives up on a syscall that has outrun its deadline: `true` when it had not finished — the worker now
    /// owns the socket; `false` when it beat the deadline, leaving `outcome` readable.
    public func abandon() -> Bool {
        state.withLock { state in
            guard state.recorded == nil else { return false }
            state.abandoned = true
            return true
        }
    }

    /// The recorded `errno`, or `nil` while the syscall is still in flight.
    public var outcome: Int32? { state.withLock { $0.recorded } }
}

/// Rations blocking `connect(2)` attempts per label once earlier attempts have parked in the kernel.
///
/// A parked connect never returns and never surfaces to the host — the queued request appears at the listener
/// only when the guest closes the fd (docs/research/2026-08-02-macos12-vsock-blocking-connect-parks.md,
/// 2026-08-02-macos12-vsock-nonblocking-connect.md) — so the thread behind one is stranded for the life of the
/// process. Unbounded, a host that never accepts would strand one thread per retry forever. Only *parked*
/// attempts are charged: an attempt whose syscall returns inside its deadline costs nothing, however many run at
/// once, so concurrent healthy dials are never refused.
///
/// Past `maxParkedAttempts` parked attempts one attempt is admitted per backoff interval — `backoffFloor`,
/// doubling per additional park in the current episode up to `backoffCeiling` — so a persistent wedge strands
/// threads at a rate that decays to one per `backoffCeiling`. Any attempt that then completes inside its
/// deadline, connected or refused with an errno, proves the host's vsock stack is answering and lifts the
/// rationing outright: the parked threads are sunk cost that traffic the host can serve must not pay for. A
/// completion also ends the episode, so the next wedge is rationed from the floor again rather than from wherever
/// the last one escalated to — parked threads are never reclaimed, so an escalation carried across episodes would
/// only ratchet.
public final class BlockingConnectGate: Sendable {
    /// Parked attempts tolerated before admission rides the backoff.
    public static let maxParkedAttempts = 3
    /// Wait before the first admission past the cap, doubled per parked attempt beyond it.
    public static let backoffFloor: TimeInterval = 10
    public static let backoffCeiling: TimeInterval = 600

    /// The process's gate, which every connect shares unless it is given its own.
    public static let process = BlockingConnectGate()

    private struct LabelState: Sendable {
        /// Attempts abandoned past their deadline whose syscall has not returned.
        var parked = 0
        /// Parks since the last attempt to complete inside its deadline whose syscalls have still not returned —
        /// the escalation driver for the current wedge, zero exactly while the host is known to be answering.
        /// Never exceeds `parked`.
        var parksThisEpisode = 0
        /// When the most recent admission was granted.
        var lastAdmissionAt = CoreInstant(nanoseconds: 0)
    }

    private let states = Locked<[String: LabelState]>([:])
    private let now: @Sendable () -> CoreInstant

    /// A gate reading monotonic time from `now`.
    public init(now: @escaping @Sendable () -> CoreInstant = { SystemScheduler().now }) {
        self.now = now
    }

    /// Whether `label` may start a blocking connect now: yes unless the label is over its parked cap with
    /// nothing completed since and its current backoff has not elapsed.
    public func admit(_ label: String) -> Bool {
        let instant = now()
        return states.withLock { states in
            var state = states[label] ?? LabelState()
            if state.parked >= Self.maxParkedAttempts, state.parksThisEpisode > 0 {
                let over = max(0, state.parksThisEpisode - Self.maxParkedAttempts)
                let backoff = min(Self.backoffFloor * pow(2, Double(over)), Self.backoffCeiling)
                let elapsed = Double(instant.nanoseconds &- state.lastAdmissionAt.nanoseconds) / 1_000_000_000
                guard elapsed >= backoff else { return false }
            }
            state.lastAdmissionAt = instant
            states[label] = state
            return true
        }
    }

    /// Charges `label` for an attempt whose deadline passed with the syscall still in the kernel. Called
    /// *before* `BlockingConnectHandoff.abandon()`, so that every `markParkReturned` — which only a worker that
    /// saw the abandoned flag can reach — is preceded by its own increment.
    public func markParked(_ label: String) {
        states.withLock { states in
            var state = states[label] ?? LabelState()
            state.parked += 1
            state.parksThisEpisode += 1
            states[label] = state
        }
    }

    /// Undoes a `markParked` whose syscall turned out to have beaten the deadline, leaving the attempt counted
    /// as completed.
    public func revertPark(_ label: String) {
        states.withLock { states in
            var state = states[label] ?? LabelState()
            state.parked = max(0, state.parked - 1)
            state.parksThisEpisode = 0
            states[label] = state
        }
    }

    /// Discharges a parked attempt whose syscall has finally returned — including from the current wedge's
    /// escalation, so a later wedge is not rationed for threads no longer stranded.
    public func markParkReturned(_ label: String) {
        states.withLock { states in
            guard var state = states[label] else { return }
            state.parked = max(0, state.parked - 1)
            state.parksThisEpisode = max(0, state.parksThisEpisode - 1)
            states[label] = state
        }
    }

    /// Records that an attempt completed inside its deadline, whatever its outcome — the host is answering, so
    /// rationing lifts and the wedge episode ends.
    public func markCompleted(_ label: String) {
        states.withLock { states in
            var state = states[label] ?? LabelState()
            state.parksThisEpisode = 0
            states[label] = state
        }
    }

    /// How many of `label`'s attempts are parked in the kernel.
    func parkedCount(_ label: String) -> Int {
        states.withLock { $0[label]?.parked ?? 0 }
    }
}
#endif
