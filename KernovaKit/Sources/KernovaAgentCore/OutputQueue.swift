/// An endpoint's queue of outputs for its driver, polled in the order they
/// were appended. The one place receive-side coalescing lives: an
/// output appended under a slot replaces that slot's pending one in place, so
/// a far side sending snapshots in a tight loop costs one output per drain.
struct OutputQueue<Output: Sendable, Slot: Hashable & Sendable>: Sendable {
    private var outputs: [Output] = []
    private var head = 0
    private var pending: [(slot: Slot, index: Int)] = []

    /// Appends `output`, replacing the unpolled one of `slot` when there is one.
    mutating func append(_ output: Output, coalescing slot: Slot? = nil) {
        guard let slot else { return outputs.append(output) }
        if let entry = pending.first(where: { $0.slot == slot }) {
            outputs[entry.index] = output
            return
        }
        pending.append((slot: slot, index: outputs.count))
        outputs.append(output)
    }

    /// Outputs not yet polled.
    var count: Int { outputs.count - head }

    /// Takes the oldest output.
    mutating func poll() -> Output? {
        guard head < outputs.count else { return nil }
        let output = outputs[head]
        pending.removeAll { $0.index == head }
        head += 1
        if head == outputs.count {
            outputs.removeAll(keepingCapacity: true)
            head = 0
        }
        return output
    }
}

/// An output queue whose outputs never coalesce.
enum NoSlot: Hashable, Sendable {}
