import Foundation

/// Process-wide pointer to the agent's `VsockHostConnection` for
/// `KernovaLogger` to forward through.
///
/// Set once during the delegate's synchronous startup, before any background
/// `Task` can emit a log line, and never reassigned after that.
enum VsockLogBridge {
    nonisolated(unsafe) static var connection: VsockHostConnection?
}
