import Foundation

/// Schedules `body` on the main run loop as a **run-loop block**, rather than as
/// a main-queue dispatch block the way `Task { @MainActor in … }` does.
///
/// Use this — and not a `Task` — for work that enters a nested event-tracking
/// loop, which on AppKit means anything that opens a menu, a modal session, or a
/// tracking drag. The two are not interchangeable there:
///
/// libdispatch drains the main queue from a run-loop source, and that drain is
/// **not re-entrant**. Work enqueued to the main queue *while the main queue is
/// already draining* cannot start until the current block returns — so a block
/// that parks inside a nested run loop starves every `DispatchQueue.main.async`
/// and every `Task { @MainActor }` for as long as it stays parked. A menu opened
/// from inside a `Task` therefore freezes: it holds the drain for the menu's
/// whole lifetime, and any UI meant to keep updating behind it stops dead until
/// the menu closes. (Observed live on #643: the paste readout's ring and its
/// dropdown row both froze on the automatic open, and both animated normally
/// when the same menu was opened by a user click — which reaches menu tracking
/// through AppKit's event path, never through the main-queue drain.)
///
/// A run-loop block has no such problem. It is dispatched by the run loop
/// itself, so the main-queue drain source stays free to fire inside whatever
/// nested loop `body` enters, and main-actor work keeps flowing.
///
/// Scheduled in `.common` modes so it still runs while some *other* tracking
/// loop happens to be up.
@MainActor
public func performOnMainRunLoop(_ body: @escaping @MainActor () -> Void) {
    RunLoop.main.perform(inModes: [.common]) {
        // The main run loop runs on the main thread by definition, so this is
        // an assertion of a fact rather than a hop.
        MainActor.assumeIsolated { body() }
    }
}
