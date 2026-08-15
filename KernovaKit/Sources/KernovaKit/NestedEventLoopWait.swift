import AppKit
import Foundation

/// Holds the main thread without parking it: runs the application's event loop
/// — input, drawing, timers, main-queue work — until `wake()` or a deadline.
///
/// A synchronous pasteboard promise callback has to occupy its thread until the
/// bytes exist; this is how it occupies the main thread while the app stays
/// live (docs/CLIPBOARD.md §8). The loop nests inside whatever is on the stack,
/// so anything the app can do can happen inside the wait — including a second
/// promise callback.
///
/// `current()` vends one only at the base of the main run loop: an
/// `NSApplication` exists and the loop is in the default mode. Nested in a
/// tracking or modal loop it would dispatch events that loop owns, so those
/// callers park instead. Verified 2026-08-15 (macOS 26): pboard delivers the
/// callback as a main-run-loop block in the default mode, and a nested
/// `nextEvent`/`sendEvent` loop there dispatches input, drains the main queue and
/// runs `MainActor` work, while a plain `RunLoop.run` drops the input it
/// receives.
final class NestedEventLoopWait: @unchecked Sendable {
    /// Marks the wake event apart from application-defined events posted by
    /// anyone else.
    private static let wakeSubtype: Int16 = 0x4C50

    /// Waits in progress on the main thread. A wake that lands after its wait
    /// returned posts nothing, so no stray event reaches `sendEvent`.
    @MainActor private static var activeWaits = 0

    private init() {}

    /// The wait for the calling thread, or `nil` where the caller must park.
    static func current() -> NestedEventLoopWait? {
        guard Thread.isMainThread, MainActor.assumeIsolated({ NSApp != nil }) else { return nil }
        let mode = RunLoop.current.currentMode
        guard mode == nil || mode == .default else { return nil }
        return NestedEventLoopWait()
    }

    /// Runs the event loop until `isResolved()` or `deadline`.
    ///
    /// Main thread only. Every event is dispatched, so `isResolved` may become
    /// true from work the loop itself ran.
    func wait(until deadline: Date, isResolved: @Sendable () -> Bool) {
        MainActor.assumeIsolated {
            Self.activeWaits += 1
            defer { Self.activeWaits -= 1 }
            while !isResolved() {
                guard
                    let event = NSApp.nextEvent(
                        matching: .any, until: deadline, inMode: .default, dequeue: true)
                else { return }
                if event.type == .applicationDefined, event.subtype.rawValue == Self.wakeSubtype {
                    continue
                }
                NSApp.sendEvent(event)
                NSApp.updateWindows()
            }
        }
    }

    /// Breaks the wait in progress, from any thread.
    ///
    /// The event is posted on the main thread itself, from a run-loop block — not
    /// a main-queue block, which a nested loop entered from the main queue would
    /// never drain (`performOnMainRunLoop`). `CFRunLoop` is safe to call from
    /// any thread; `RunLoop` is not.
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
