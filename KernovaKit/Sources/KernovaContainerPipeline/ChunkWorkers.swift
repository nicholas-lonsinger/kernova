import Dispatch

/// The threads one pipeline's chunk work runs on: `count` serial lanes of its own, so at most `count` chunks are
/// worked at once and work handed to one lane runs in the order it was handed in. With no lanes, work runs in the
/// caller as it is handed in.
package final class ChunkWorkers: Sendable {
    /// The lanes.
    package let count: Int
    private let lanes: [DispatchQueue]
    private let around: @Sendable (_ lane: Int, _ work: () -> Void) -> Void

    /// `count` lanes, each running its work through `around`, which must call the work it is given exactly once.
    ///
    /// - Parameters:
    ///   - count: The lanes; 0 runs work in the caller.
    ///   - around: What each piece of work runs inside, on its lane, given the lane's index (0 in the caller).
    package init(count: Int, around: @escaping @Sendable (_ lane: Int, _ work: () -> Void) -> Void = { $1() }) {
        precondition(count >= 0, "a negative lane count")
        self.count = count
        lanes = (0..<count).map { DispatchQueue(label: "app.kernova.container-pipeline.lane-\($0)") }
        self.around = around
    }

    /// Runs `work` on lane `lane` modulo the lane count, after the work handed to that lane before it, or in the
    /// caller when there are no lanes.
    func run(onLane lane: Int, _ work: @escaping @Sendable () -> Void) {
        guard !lanes.isEmpty else {
            around(0, work)
            return
        }
        let around = self.around
        let index = lane % lanes.count
        lanes[index].async { around(index, work) }
    }

    /// Returns once every lane has finished the work handed to it.
    func drain() {
        for lane in lanes { lane.sync {} }
    }
}
