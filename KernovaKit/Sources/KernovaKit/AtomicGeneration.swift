import Foundation

/// A thread-safe holder for the current outbound offer generation.
///
/// The streaming sender's supersession check (`isCurrent`) runs on a transfer
/// queue, off the owning actor, so it can't read the service's actor-isolated
/// generation directly. The service updates this box on its actor whenever the
/// current offer changes; the sender reads it from its queue. `0` means "no
/// current offer".
public final class AtomicGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    /// Creates a holder seeded with the "no current offer" sentinel (`0`).
    public init() {}

    /// Sets the current generation (call when a new offer supersedes the old).
    public func set(_ generation: UInt64) {
        lock.withLock { value = generation }
    }

    /// `true` when `generation` is still the current offer.
    public func isCurrent(_ generation: UInt64) -> Bool {
        lock.withLock { value == generation }
    }
}
