import Foundation
import Testing

@testable import KernovaKit

@Suite("EngineClock sleep cancellation")
struct EngineClockTests {
    @Test("Monotonic sleep throws on a cancelled task even for a non-positive interval")
    func monotonicSleepThrowsWhenCancelled() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await MonotonicEngineClock().sleep(for: 0)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("Continuous sleep matches: throws on a cancelled task for a past deadline")
    func continuousSleepThrowsWhenCancelled() async {
        guard #available(macOS 13.0, *) else { return }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await ContinuousEngineClock().sleep(for: 0)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
