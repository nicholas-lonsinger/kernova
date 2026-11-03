#if os(macOS)
import Darwin
import Dispatch
import KernovaAgentInstall

/// The launchd job running the peer the rollback check judges, which the check asks for the peer's process.
///
/// The check runs as a job of the same domain — the user's GUI session, or `system` — so `launchctl list`,
/// which lists the caller's domain, lists the peer's job.
public struct LaunchdServiceManager: ServiceManager {
    /// The peer's job.
    public let label: String

    /// The manager of the job `label`.
    public init(label: String) {
        self.label = label
    }

    public func peerProcessID() throws -> UInt32 {
        let arguments = ["launchctl", "list"]
        let (status, output) = Installer.capture(arguments)
        guard status == 0 else { throw Installer.Failure.command(arguments: arguments, status: status) }
        return Self.processID(of: label, inListing: String(decoding: output, as: UTF8.self))
    }

    /// The process `label`'s job runs, read from `launchctl list`'s listing: three columns, the first the
    /// job's process id when it is running, `-` when it is not, the third its label (launchctl(1), `list`).
    /// 0 when the job is not running or not listed.
    static func processID(of label: String, inListing listing: String) -> UInt32 {
        for line in listing.split(separator: "\n") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3, columns[2] == label else { continue }
            return UInt32(columns[0]) ?? 0
        }
        return 0
    }
}

/// Stopping a launchd job and waiting until launchd has let it go, as an install needs before it bootstraps the
/// job's label again.
public enum LaunchdStop {
    /// How long a job is given to go.
    public static let limit = DispatchTimeInterval.seconds(10)

    /// Boots `serviceTarget` (`gui/<uid>/<label>` or `system/<label>`) out, then waits until launchd no longer
    /// knows it: `launchctl print` of it fails, as launchctl(1)'s EXIT STATUS gives any subcommand that does not
    /// succeed. True once it is gone, a job that was never loaded included; false when it is still there at
    /// `limit`.
    public static func stop(_ serviceTarget: String, limit: DispatchTimeInterval = limit) -> Bool {
        _ = quiet(["launchctl", "bootout", serviceTarget])
        let deadline = DispatchTime.now() + limit
        while quiet(["launchctl", "print", serviceTarget]) == 0 {
            guard DispatchTime.now() < deadline else { return false }
            usleep(100_000)
        }
        return true
    }

    /// Runs `arguments` with their output and errors discarded, answering the exit status.
    private static func quiet(_ arguments: [String]) -> Int32 {
        Installer.spawn(["/bin/sh", "-c", #""$@" >/dev/null 2>&1"#, "sh"] + arguments)
    }
}
#endif
