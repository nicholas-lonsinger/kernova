import Foundation

/// A one-way flag: one thread sets it, any other reads it.
///
/// Never clears, so a reader that sees it set can act on that without holding a
/// lock of its own across whatever it does next.
final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}
