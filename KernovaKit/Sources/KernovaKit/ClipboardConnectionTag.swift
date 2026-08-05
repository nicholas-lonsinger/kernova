import Foundation

/// Log-only coordinate identifying one clipboard connection within a process.
///
/// Offer generations and the `transfer_id`s built from them are scoped to a live
/// connection and restart with it, so one log holds several unrelated lines
/// carrying the same numbers; `conn=` tells them apart. The tag is never
/// serialized and no wire value is derived from it.
public struct ClipboardConnectionTag: Sendable, CustomStringConvertible {
    private static let lock = NSLock()
    // `nonisolated(unsafe)`: every read and write happens inside `lock`.
    private nonisolated(unsafe) static var lastSequence: UInt64 = 0

    /// Mint order within this process, counting from 1; `0` means no connection.
    public let sequence: UInt64

    /// Rendered ahead of `sequence` when the log record carries no pid of its
    /// own, else `nil`.
    public let processIdentifier: Int32?

    private init(sequence: UInt64, processIdentifier: Int32?) {
        self.sequence = sequence
        self.processIdentifier = processIdentifier
    }

    /// `<sequence>` for a host tag, `<pid>.<sequence>` for a guest one.
    public var description: String {
        guard let processIdentifier else { return "\(sequence)" }
        return "\(processIdentifier).\(sequence)"
    }

    /// Mints the next tag for a host-side connection, rendering as the bare
    /// sequence — a host record already carries the host process's pid.
    public static func nextHost() -> ClipboardConnectionTag {
        ClipboardConnectionTag(sequence: nextSequence(), processIdentifier: nil)
    }

    /// Mints the next tag for a guest-side connection, rendering as
    /// `<pid>.<sequence>` — a guest record forwarded to the host carries no pid,
    /// and the agent process restarting is what restarts the sequence.
    public static func nextGuest() -> ClipboardConnectionTag {
        ClipboardConnectionTag(
            sequence: nextSequence(), processIdentifier: ProcessInfo.processInfo.processIdentifier)
    }

    /// The guest tag in effect before the agent has served a connection.
    public static let guestUnconnected = ClipboardConnectionTag(
        sequence: 0, processIdentifier: ProcessInfo.processInfo.processIdentifier)

    private static func nextSequence() -> UInt64 {
        lock.withLock {
            lastSequence += 1
            return lastSequence
        }
    }
}
