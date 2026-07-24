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
    // nonisolated(unsafe): safe under the set-once-before-background-reads
    // contract in the doc comment above.
    nonisolated(unsafe) static var connection: VsockHostConnection?
}
