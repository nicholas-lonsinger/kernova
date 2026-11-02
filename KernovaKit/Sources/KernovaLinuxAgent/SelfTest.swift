#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// Apple's Dispatch marks its source protocols `Sendable`; swift-corelibs-libdispatch does not.
@preconcurrency import Dispatch
import KernovaSynchronization

/// Runs a staged agent's `self-test`, which only a binary that executes on this kernel and reads its own
/// file passes.
enum SelfTest {
    /// How a run ended.
    enum Outcome: Equatable, Sendable {
        /// It exited 0 within the limit.
        case passed
        /// It exited with this nonzero status.
        case exited(Int32)
        /// A signal ended it.
        case signaled(Int32)
        /// It was still running at the limit, and was killed.
        case timedOut
        /// It could not be started; the error number says why.
        case couldNotStart(Int32)
    }

    /// How long a self-test may take.
    static let limit = DispatchTimeInterval.seconds(10)

    /// Runs `executable self-test`, its output discarded, killing it at `limit`.
    static func run(_ executable: String, limit: DispatchTimeInterval = limit) -> Outcome {
        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor: Int32 in [0, 1, 2] {
            posix_spawn_file_actions_addopen(
                &actions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        let arguments = [executable, "self-test"]
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid = pid_t()
        let started = argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { envpBuffer -> Int32 in
                guard let argvBase = argvBuffer.baseAddress, let envpBase = envpBuffer.baseAddress else {
                    return EINVAL
                }
                return posix_spawn(&pid, executable, &actions, nil, argvBase, envpBase)
            }
        }
        guard started == 0 else { return .couldNotStart(started) }

        let status = Locked<Int32>(0)
        let exited = DispatchSemaphore(value: 0)
        let child = pid
        DispatchQueue.global().async {
            var raw: Int32 = 0
            while waitpid(child, &raw, 0) < 0, errno == EINTR {}
            status.withLock { $0 = raw }
            exited.signal()
        }
        guard exited.wait(timeout: .now() + limit) == .success else {
            kill(child, SIGKILL)
            exited.wait()
            return .timedOut
        }
        let raw = status.withLock { $0 }
        let signal = raw & 0x7F
        guard signal == 0 else { return .signaled(signal) }
        let code = (raw >> 8) & 0xFF
        return code == 0 ? .passed : .exited(code)
    }
}
#endif
