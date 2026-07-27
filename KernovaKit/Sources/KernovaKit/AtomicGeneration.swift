import Foundation

/// A thread-safe holder for the current outbound offer generation.
///
/// The owning service writes it from its actor; the streaming sender reads it
/// from its transfer queue. `0` means "no current offer".
public final class AtomicGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    /// Creates a holder at the "no current offer" sentinel.
    public init() {}

    /// Sets the current generation.
    public func set(_ generation: UInt64) {
        lock.withLock { value = generation }
    }

    /// `true` when `generation` is still the current offer.
    public func isCurrent(_ generation: UInt64) -> Bool {
        lock.withLock { value == generation }
    }
}
