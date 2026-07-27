import Foundation

/// Schedules `body` on the main run loop as a **run-loop block**, not as a
/// main-queue dispatch block the way `Task { @MainActor in … }` does.
///
/// Use this — never a `Task` — for anything entering a nested event-tracking loop
/// (a menu, a modal session, a drag): the main-queue drain is not re-entrant, so
/// a block parked in a nested loop starves every later `DispatchQueue.main.async`
/// and `Task { @MainActor }` (observed as a paste readout frozen for an
/// auto-opened menu's lifetime). A run-loop block leaves that drain free.
@MainActor
public func performOnMainRunLoop(_ body: @escaping @MainActor () -> Void) {
    RunLoop.main.perform(inModes: [.common]) {
        // The main run loop runs on the main thread by definition.
        MainActor.assumeIsolated { body() }
    }
}
