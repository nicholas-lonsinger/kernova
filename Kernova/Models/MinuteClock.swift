import Foundation

/// The present, to the minute, for text stated relative to it.
///
/// Time passing changes no model value, so an observation never wakes on it
/// alone: a reader of ``now`` wakes on each tick instead, and every reader of
/// one clock wakes on the same tick.
@MainActor
@Observable
final class MinuteClock {
    /// The moment of the latest tick.
    private(set) var now: Date

    /// A clock standing at `now` until ``advance(to:)`` moves it.
    init(now: Date = Date()) {
        self.now = now
    }

    /// The app's clock, ticking at the start of each wall-clock minute.
    static let wall: MinuteClock = {
        let clock = MinuteClock()
        clock.tickEachMinute()
        return clock
    }()

    /// Moves the clock to `date`, waking every reader of ``now``.
    func advance(to date: Date) {
        now = date
    }

    private func tickEachMinute() {
        Task { [weak self] in
            while true {
                let untilNextMinute = 60 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
                guard (try? await Task.sleep(for: .seconds(untilNextMinute))) != nil, let self else { return }
                self.advance(to: Date())
            }
        }
    }
}
