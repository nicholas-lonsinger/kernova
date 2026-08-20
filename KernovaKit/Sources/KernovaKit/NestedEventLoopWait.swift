import AppKit
import Foundation

/// Holds the main thread without parking it: runs the application's event loop
/// — input, drawing, timers, main-queue work — until resolved or a deadline.
///
/// A synchronous pasteboard promise callback has to occupy its thread until the
/// bytes exist; this is how it occupies the main thread while the app stays
/// live (docs/CLIPBOARD.md §8). The loop nests inside whatever is on the stack,
/// so anything the app can do can happen inside the wait — including a second
/// promise callback, whose own wait nests inside this one, and a tracking or
/// modal loop (a menu, a drag, a sheet) that then holds the callback's return
/// until it ends.
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
final class NestedEventLoopWait: @unchecked Sendable {
    /// Marks the wake event apart from application-defined events posted by
    /// anyone else.
    private static let wakeSubtype: Int16 = 0x4C50

    /// Waits in progress on the main thread; a wake posts nothing once its wait
    /// has returned, so no stray event outlives it.
    @MainActor private static var activeWaits = 0

    /// Longest a single `nextEvent` blocks before the loop re-checks its
    /// resolution. The wake below resolves the common case immediately; this
    /// bounds the one it cannot — a wait nested inside another consumes the
    /// outer's wake and discards it, so the outer must notice on its own.
    /// Imperceptible on a paste, coarse enough not to spin.
    private static let sliceSeconds: TimeInterval = 0.1

    #if DEBUG
    /// Test seam: replaces `sliceSeconds`, so a test can tell a wait the wake
    /// broke from one the next slice noticed.
    @MainActor static var sliceSecondsForTesting: TimeInterval?

    /// Test seam: makes `current()` decline on the main thread, standing in for
    /// the tracking or modal loop a test bundle has no way to enter.
    @MainActor static var declinesForTesting = false
    #endif

    private init() {}

    /// The wait for the calling thread, or `nil` where the caller must park.
    static func current() -> NestedEventLoopWait? {
        guard Thread.isMainThread else { return nil }
        #if DEBUG
        guard !MainActor.assumeIsolated({ declinesForTesting }) else { return nil }
        #endif
        guard MainActor.assumeIsolated({ NSApp != nil }) else { return nil }
        let mode = RunLoop.current.currentMode
        guard mode == nil || mode == .default else { return nil }
        return NestedEventLoopWait()
    }

    /// Runs the event loop until `isResolved()` or `timeout` elapses.
    ///
    /// Main thread only. Every event is dispatched, so `isResolved` may become
    /// true from work the loop itself ran.
    func wait(timeout: TimeInterval, isResolved: @Sendable () -> Bool) {
        MainActor.assumeIsolated {
            Self.activeWaits += 1
            defer { Self.activeWaits -= 1 }
            // Uptime, like the parked branch's semaphore deadline — a wall-clock
            // step must not stretch or cut the backstop.
            let deadline = DispatchTime.now() + timeout
            var slice = Self.sliceSeconds
            #if DEBUG
            slice = Self.sliceSecondsForTesting ?? slice
            #endif
            while !isResolved() {
                let now = DispatchTime.now()
                guard now < deadline else { return }
                let remaining =
                    Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000
                let sliceEnd = Date(timeIntervalSinceNow: min(remaining, slice))
                // One pool per pass, as `NSApplication.run` drains: what the
                // event dispatch autoreleases is freed per event, not held for
                // the whole pull by the callout's own pool.
                autoreleasepool {
                    guard
                        let event = NSApp.nextEvent(
                            matching: .any, until: sliceEnd, inMode: .default, dequeue: true),
                        !(event.type == .applicationDefined
                            && event.subtype.rawValue == Self.wakeSubtype)
                    else { return }
                    NSApp.sendEvent(event)
                    NSApp.updateWindows()
                }
            }
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
                guard Self.activeWaits > 0,
                    let event = NSEvent.otherEvent(
                        with: .applicationDefined, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                        context: nil, subtype: Self.wakeSubtype, data1: 0, data2: 0)
                else { return }
                NSApp.postEvent(event, atStart: true)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
