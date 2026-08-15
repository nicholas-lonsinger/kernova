import AppKit
import Foundation

/// Holds the main thread without parking it: runs the application's event loop
/// — input, drawing, timers, main-queue work — until `wake()` or a deadline.
///
/// A synchronous pasteboard promise callback has to occupy its thread until the
/// bytes exist; this is how it occupies the main thread while the app stays
/// live (docs/CLIPBOARD.md §8). The loop nests inside whatever is on the stack,
/// so anything the app can do can happen inside the wait — including a second
/// promise callback, whose own wait nests inside this one.
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
    /// Marks a wake event apart from application-defined events posted by anyone
    /// else; `data1` carries the id of the wait it targets.
    private static let wakeSubtype: Int16 = 0x4C50

    /// Ids of waits currently on the stack. A wake for an id not here is stale
    /// (its wait already returned) and is dropped rather than propagated.
    @MainActor private static var activeIDs: Set<Int> = []
    @MainActor private static var nextID = 0

    private let id: Int

    @MainActor private init() {
        Self.nextID += 1
        id = Self.nextID
    }

    /// The wait for the calling thread, or `nil` where the caller must park.
    static func current() -> NestedEventLoopWait? {
        guard Thread.isMainThread, MainActor.assumeIsolated({ NSApp != nil }) else { return nil }
        let mode = RunLoop.current.currentMode
        guard mode == nil || mode == .default else { return nil }
        return MainActor.assumeIsolated { NestedEventLoopWait() }
    }

    /// Runs the event loop until `isResolved()` or `deadline`.
    ///
    /// Main thread only. Every event is dispatched, so `isResolved` may become
    /// true from work the loop itself ran.
    ///
    /// Wake events are targeted by id, but only the innermost wait blocks in
    /// `nextEvent`, so it receives an outer wait's wake too. It cannot act on one
    /// (that wait is suspended below it on the stack), so it stashes it and
    /// re-posts it on exit — the outer wait, resuming, then gets its own wake.
    func wait(until deadline: Date, isResolved: @Sendable () -> Bool) {
        MainActor.assumeIsolated {
            Self.activeIDs.insert(id)
            var stashed: [NSEvent] = []
            defer {
                Self.activeIDs.remove(id)
                for event in stashed { NSApp.postEvent(event, atStart: false) }
            }
            while !isResolved() {
                guard
                    let event = NSApp.nextEvent(
                        matching: .any, until: deadline, inMode: .default, dequeue: true)
                else { return }
                if event.type == .applicationDefined, event.subtype.rawValue == Self.wakeSubtype {
                    let target = Int(event.data1)
                    // Mine: re-check. An outer's (still on the stack): hold it for
                    // that wait to see when it resumes. A finished wait's: drop it.
                    if target != id, Self.activeIDs.contains(target) { stashed.append(event) }
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
    /// never drain (`performOnMainRunLoop`). `CFRunLoop` is safe to call from any
    /// thread; `NSApp`/`RunLoop` are not.
    func wake() {
        let target = id
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                guard Self.activeIDs.contains(target),
                    let event = NSEvent.otherEvent(
                        with: .applicationDefined, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                        context: nil, subtype: Self.wakeSubtype, data1: target, data2: 0)
                else { return }
                NSApp.postEvent(event, atStart: true)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
