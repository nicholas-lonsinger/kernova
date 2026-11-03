import Dispatch
import KernovaSynchronization

/// A value one lane works out and the window's owner takes: set once, by the work, before it signals; taken once,
/// by the owner.
final class Pending<Value: Sendable>: Sendable {
    private let value = Locked<Value?>(nil)
    private let done = DispatchSemaphore(value: 0)

    func fulfill(_ result: Value) {
        value.withLock { $0 = result }
        done.signal()
    }

    /// The value, if the work has set it.
    func take() -> Value? {
        value.withLock { value in
            defer { value = nil }
            return value
        }
    }

    /// The value, once the work has set it.
    func wait() -> Value {
        while true {
            if let value = take() { return value }
            done.wait()
        }
    }
}

/// Values in the order they were handed in, some still being worked out on a `ChunkWorkers` lane, taken back in
/// that order.
///
/// It holds at most `capacity` values: handing one to a full window first waits for its oldest and hands that back,
/// so no path holds more. The lanes are its own; while it holds a value being worked out, only that value's work
/// touches it, and the window takes it only once the work has set it. Ending the window — `cancel()` or its last
/// release — drops every value and returns once no work it handed out is still running.
final class OrderedWindow<Value: Sendable> {
    private enum Slot {
        case ready(Value)
        case working(Pending<Value>)
    }

    /// The most values held at once.
    let capacity: Int
    private let workers: ChunkWorkers
    /// A ring of `capacity` slots, the oldest at `head`.
    private var slots: [(slot: Slot, bytes: Int)?]
    private var head = 0
    /// The values held.
    private(set) var count = 0
    private var nextLane = 0
    /// The bytes the values held account for, as each was handed in.
    private(set) var heldBytes = 0
    /// The most values held at once so far.
    private(set) var mostHeld = 0
    /// The most bytes held at once so far.
    private(set) var mostHeldBytes = 0

    /// A window of `capacity` values worked out on `workers`.
    init(capacity: Int, workers: ChunkWorkers) {
        precondition(capacity > 0, "a window holds at least one value")
        self.capacity = capacity
        self.workers = workers
        slots = Array(repeating: nil, count: capacity)
    }

    deinit {
        cancel()
    }

    /// Holds `value`, ready now, after the values held.
    ///
    /// - Parameters:
    ///   - value: The value.
    ///   - bytes: The bytes it holds.
    /// - Returns: The oldest value, waited for, when the window was full.
    func append(_ value: Value, bytes: Int) -> Value? {
        let evicted = count == capacity ? takeOldest() : nil
        hold(.ready(value), bytes: bytes)
        return evicted
    }

    /// Holds the value `work` works out on the next lane, after the values held.
    ///
    /// - Parameters:
    ///   - bytes: The bytes the work holds at most: its input and its result.
    ///   - work: The work, run once.
    /// - Returns: The oldest value, waited for, when the window was full.
    func append(bytes: Int, working work: @escaping @Sendable () -> Value) -> Value? {
        let evicted = count == capacity ? takeOldest() : nil
        let pending = Pending<Value>()
        hold(.working(pending), bytes: bytes)
        let lane = nextLane
        nextLane = (nextLane + 1) % max(1, workers.count)
        workers.run(onLane: lane) { pending.fulfill(work()) }
        return evicted
    }

    /// The oldest value, when it is ready.
    func takeReady() -> Value? {
        guard let (slot, _) = slots[head] else { return nil }
        switch slot {
        case .ready(let value):
            release()
            return value
        case .working(let pending):
            guard let value = pending.take() else { return nil }
            release()
            return value
        }
    }

    /// The oldest value, waited for; nil when none is held.
    func takeOldest() -> Value? {
        guard let (slot, _) = slots[head] else { return nil }
        let value: Value
        switch slot {
        case .ready(let ready): value = ready
        case .working(let pending): value = pending.wait()
        }
        release()
        return value
    }

    /// Drops every value held, returning once no work the window handed out is still running.
    func cancel() {
        for index in slots.indices { slots[index] = nil }
        count = 0
        heldBytes = 0
        workers.drain()
    }

    private func hold(_ slot: Slot, bytes: Int) {
        slots[(head + count) % capacity] = (slot, bytes)
        count += 1
        heldBytes += bytes
        mostHeld = max(mostHeld, count)
        mostHeldBytes = max(mostHeldBytes, heldBytes)
    }

    private func release() {
        heldBytes -= slots[head]?.bytes ?? 0
        slots[head] = nil
        head = (head + 1) % capacity
        count -= 1
    }
}
