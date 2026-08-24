import Foundation

/// A thread-safe holder for the current outbound offer generation.
///
/// The owning service writes it from its actor; the streaming sender reads it
/// from its transfer queue. `0` means "no current offer".
final class AtomicGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    /// Creates a holder at the "no current offer" sentinel.
    init() {}

    /// Sets the current generation.
    func set(_ generation: UInt64) {
        lock.withLock { value = generation }
    }

    /// `true` when `generation` is still the current offer.
    func isCurrent(_ generation: UInt64) -> Bool {
        lock.withLock { value == generation }
    }
}
