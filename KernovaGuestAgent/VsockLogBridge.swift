import Foundation

/// Process-wide pointer to the agent's `VsockHostConnection`, used by
/// `KernovaLogger` to find the active connection without explicit
/// dependency injection at every `private static let logger = …`
/// declaration site.
///
/// Set exactly once during `main.swift`'s synchronous startup, before any
/// background `Task` fires a log line. After that the value is read-only
/// in practice — the underlying `VsockHostConnection` handles its own
/// thread safety (`@unchecked Sendable` + internal locking).
enum VsockLogBridge {

    // RATIONALE: nonisolated(unsafe) is appropriate here because assignment
    // happens once on the main thread during top-level `main.swift`
    // execution, before the reconnect Task or any logger calls happen on
    // background threads. There is no concurrent write contention.
    nonisolated(unsafe) static var connection: VsockHostConnection?
}
