import Foundation

/// The one poll of a pasteboard in this process: NSPasteboard posts no change notification, so whatever must hear
/// that its change count moved observes this. A pasteboard is polled while anything observes it, and no longer
/// once nothing does.
///
/// Each poll calls every observer, in ``Turn`` order and, within a turn, in the order they began observing; each
/// compares the change count with a baseline of its own, which its own writes move.
@MainActor
public final class ClipboardPasteboardWatch {
    /// When an observer hears a poll, relative to the others.
    public enum Turn: Comparable, Sendable {
        /// Ends what the change replaced: a write, or a concealed copy sent of what the pasteboard held. Heard
        /// first, so all a replaced write held is let go before anything reads what replaced it.
        case standingWrites
        /// Reads what the change put on the pasteboard.
        case newCopies
    }

    /// One observer's hold on a pasteboard's watch: it observes until it is cancelled or its holder lets it go.
    @MainActor
    public final class Observation {
        fileprivate let id: Int
        fileprivate weak var watch: ClipboardPasteboardWatch?

        fileprivate init(id: Int, watch: ClipboardPasteboardWatch) {
            self.id = id
            self.watch = watch
        }

        /// Stops observing.
        public func cancel() {
            watch?.remove(id)
            watch = nil
        }

        isolated deinit {
            cancel()
        }
    }

    /// One observer, which the watch holds apart from its ``Observation``, so letting that go ends it.
    private struct Observer {
        let id: Int
        let turn: Turn
        let heard: @MainActor () -> Void
    }

    /// Every pasteboard observed now, by identity.
    private static var watches: [ObjectIdentifier: ClipboardPasteboardWatch] = [:]

    /// How often a pasteboard is polled.
    private static let interval: TimeInterval = 0.5

    /// Held so its identity names no other pasteboard while it is watched; each observer reads its change count
    /// itself.
    private let pasteboard: AnyObject
    private var observers: [Observer] = []
    private var nextID = 0
    private var timer: Timer?

    private init(pasteboard: AnyObject) {
        self.pasteboard = pasteboard
    }

    /// Calls `heard` at each poll of `pasteboard`, in `turn`, until the observation returned is cancelled or let go.
    public static func observe(
        _ pasteboard: AnyObject, in turn: Turn, _ heard: @escaping @MainActor () -> Void
    ) -> Observation {
        let key = ObjectIdentifier(pasteboard)
        let watch = watches[key] ?? ClipboardPasteboardWatch(pasteboard: pasteboard)
        watches[key] = watch
        let id = watch.nextID
        watch.nextID += 1
        let position = watch.observers.firstIndex { $0.turn > turn } ?? watch.observers.endIndex
        watch.observers.insert(Observer(id: id, turn: turn, heard: heard), at: position)
        watch.startPolling()
        return Observation(id: id, watch: watch)
    }

    /// Polls once, now: every observer standing when it begins hears it, but one an earlier one cancelled.
    func poll() {
        for observer in observers where observers.contains(where: { $0.id == observer.id }) {
            observer.heard()
        }
    }

    private func startPolling() {
        guard timer == nil else { return }
        // A run-loop timer, not a dispatch timer on `.main`: an observer reads promised flavors, which fire another
        // VM's provider synchronously, and that fire's serviced wait can drain the main queue only when it is not
        // itself inside a main-queue callout (`NestedEventLoopWait`). Default mode only: a poll that would land
        // inside a tracking or modal loop waits for the loop to end rather than parking the main thread on it.
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            // The main run loop fires this on the main thread.
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func remove(_ id: Int) {
        observers.removeAll { $0.id == id }
        guard observers.isEmpty else { return }
        timer?.invalidate()
        timer = nil
        Self.watches[ObjectIdentifier(pasteboard)] = nil
    }

    #if DEBUG
    /// Whether `pasteboard` is polled now.
    static func isPollingForTesting(_ pasteboard: AnyObject) -> Bool {
        watches[ObjectIdentifier(pasteboard)]?.timer != nil
    }

    /// Polls `pasteboard` once, now, when anything observes it.
    static func pollForTesting(_ pasteboard: AnyObject) {
        watches[ObjectIdentifier(pasteboard)]?.poll()
    }
    #endif
}
