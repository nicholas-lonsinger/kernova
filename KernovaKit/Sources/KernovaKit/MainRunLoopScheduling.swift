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

/// The one bridge onto the main actor from code that is not on it.
public enum MainActorBridge {
    /// Runs `body` on the main actor and returns its result, from either the
    /// main thread or off it.
    ///
    /// The off-main branch blocks the caller, so this belongs on a path that
    /// already holds a thread — a pasteboard provider fire, a drop worker — and
    /// never on one the main actor may be waiting for.
    @discardableResult
    public static func sync<T: Sendable>(_ body: @MainActor () -> T) -> T {
        Thread.isMainThread
            ? MainActor.assumeIsolated { body() }
            : DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }

    /// Queues `body` for the next turn of the main queue, from the main thread
    /// or off it.
    ///
    /// Never inline, even when the caller is already on the main actor: the
    /// serial main queue is what orders these against the reporter emissions
    /// ``ClipboardTransferOperation`` queues the same way, and a caller that ran
    /// inline would jump ahead of everything already waiting there.
    public static func async(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
    }
}
