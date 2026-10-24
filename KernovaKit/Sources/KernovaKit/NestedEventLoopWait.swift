import AppKit
import Foundation

/// Holds the main thread without parking it: runs the application's event loop
/// — input, drawing, timers, main-queue work — until resolved or a deadline.
///
/// A synchronous pasteboard promise callback has to occupy its thread until the
/// bytes exist; this is how it occupies the main thread while the app stays
/// live. The loop nests inside whatever is on the stack,
/// so anything the app can do can happen inside the wait — including a second
/// promise callback, whose own wait nests inside this one, and a tracking or
/// modal loop (a menu, a drag, a sheet) that then holds the callback's return
/// until it ends.
///
/// A resolution reaches the wait as a wake event that ``wake()`` posts. Two
/// mechanisms cover a wake that another loop dequeues first:
///
/// - A wait nested inside this one discards every wake it dequeues, this
///   wait's included, so a wait that returns while another is active posts
///   the enclosing wait a fresh one.
/// - Any other loop entered inside this wait's `nextEvent` is covered only by
///   ``slice``: each `nextEvent` blocks at most that long before the wait
///   re-checks its resolution.
///
/// `current()` vends one only at the base of the main run loop: an
/// `NSApplication` exists and the loop is in the default mode. Nested in a
/// tracking or modal loop it would dispatch events that loop owns, so those
/// callers park instead. Entered from a main-queue callout — a
/// `DispatchQueue.main` block, a dispatch timer on `.main`, `MainActor` task
/// work — the loop still dispatches events and run-loop sources, but main-queue
/// work stays queued until that callout returns (`performOnMainRunLoop`), so
/// whatever fires a promise synchronously does so from the run loop's base: an
/// event handler, a run-loop timer. Verified 2026-08-15 (macOS 26): pboard
/// delivers the callback as a main-run-loop block in the default mode, and a
/// nested `nextEvent`/`sendEvent` loop there dispatches input, drains the main
/// queue and runs `MainActor` work, while a plain `RunLoop.run` drops the input
/// it receives.
final class NestedEventLoopWait: Sendable {
    /// How a ``wait(timeout:isResolved:)`` ended.
    enum Ending: Sendable, Equatable {
        /// The wait saw `isResolved()` hold before either `.deadline` case.
        case resolved
        /// The wait's own final `nextEvent`, the one bounded by the deadline,
        /// returned with no event, or a pass began past the deadline — whether
        /// or not `isResolved()` holds by then.
        case deadline
    }

    /// Longest a single `nextEvent` blocks before the wait re-checks its
    /// resolution, in production.
    ///
    /// Bounds the stall when a loop entered from a run-loop callout inside the
    /// wait's `nextEvent` dequeues the wake: Apple does not document which
    /// AppKit loops dequeue application-defined events, and when such a loop
    /// ends, nothing returns from the wait's `nextEvent`. Menu tracking enters
    /// that way: `performClick` from `performOnMainRunLoop` in
    /// `TransientStatusItemPopover.statusItemTapped`.
    static let defaultSlice: TimeInterval = 0.1

    /// Marks the wake event apart from application-defined events posted by
    /// anyone else.
    private static let wakeSubtype: Int16 = 0x4C50

    /// Waits in progress on the main thread. ``wake()`` posts only while one
    /// is, but a wait that returns nested posts its enclosing wait a wake that
    /// can outlive it; one still queued after every wait has returned reaches
    /// `NSApp.run`, which dispatches an application-defined event addressed to
    /// no window to nothing.
    @MainActor private static var activeWaits = 0

    /// This wait's ``defaultSlice``.
    private let slice: TimeInterval

    #if DEBUG
    /// How each of this instance's waits ended, in order. Test-only.
    @MainActor private(set) var endingsForTesting: [Ending] = []
    #endif

    private init(slice: TimeInterval) {
        self.slice = slice
    }

    /// Vends a wait for the calling thread.
    ///
    /// - Parameter slice: longest one `nextEvent` blocks; see ``defaultSlice``.
    /// - Returns: the wait, or `nil` where the caller must park.
    static func current(slice: TimeInterval = defaultSlice) -> NestedEventLoopWait? {
        guard Thread.isMainThread else { return nil }
        guard MainActor.assumeIsolated({ NSApp != nil }) else { return nil }
        let mode = RunLoop.current.currentMode
        guard mode == nil || mode == .default else { return nil }
        return NestedEventLoopWait(slice: slice)
    }

    /// Runs the event loop until `isResolved()` or `timeout` elapses.
    ///
    /// Main thread only. Every event is dispatched, so `isResolved` may become
    /// true from work the loop itself ran; anything else that makes it true
    /// calls ``wake()``.
    func wait(timeout: TimeInterval, isResolved: @Sendable () -> Bool) -> Ending {
        MainActor.assumeIsolated {
            Self.activeWaits += 1
            defer {
                Self.activeWaits -= 1
                if Self.activeWaits > 0 { Self.postWake() }
            }
            let ending = runEventLoop(timeout: timeout, isResolved: isResolved)
            #if DEBUG
            endingsForTesting.append(ending)
            #endif
            return ending
        }
    }

    /// Breaks the wait in progress, from any thread.
    ///
    /// The event is posted on the main thread itself, from a run-loop block — not
    /// a main-queue block, which a nested loop entered from the main queue would
    /// never drain (`performOnMainRunLoop`). `CFRunLoop` is safe to call from any
    /// thread; `NSApp` is not.
    func wake() {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                guard Self.activeWaits > 0 else { return }
                Self.postWake()
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    @MainActor
    private func runEventLoop(timeout: TimeInterval, isResolved: @Sendable () -> Bool) -> Ending {
        // Uptime, like the parked branch's semaphore deadline — a wall-clock
        // step must not stretch or cut the backstop.
        let deadline = DispatchTime.now() + timeout
        while true {
            if isResolved() { return .resolved }
            let now = DispatchTime.now()
            guard now < deadline else { return .deadline }
            let remaining =
                Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000
            let lastPass = remaining <= slice
            let passEnd = Date(timeIntervalSinceNow: min(remaining, slice))
            var dequeued = false
            // One pool per pass, as `NSApplication.run` drains: what the
            // event dispatch autoreleases is freed per event, not held for
            // the whole pull by the callout's own pool.
            autoreleasepool {
                guard
                    let event = NSApp.nextEvent(
                        matching: .any, until: passEnd, inMode: .default, dequeue: true)
                else { return }
                dequeued = true
                guard
                    !(event.type == .applicationDefined
                        && event.subtype.rawValue == Self.wakeSubtype)
                else { return }
                NSApp.sendEvent(event)
                NSApp.updateWindows()
            }
            if !dequeued && lastPass { return .deadline }
        }
    }

    /// Queues a wake event for the innermost wait in progress.
    @MainActor
    private static func postWake() {
        guard
            let event = NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                context: nil, subtype: wakeSubtype, data1: 0, data2: 0)
        else {
            assertionFailure("NSEvent.otherEvent refused the wake event's constant fields")
            return
        }
        NSApp.postEvent(event, atStart: true)
    }
}
