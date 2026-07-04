import CoreFoundation
import Foundation

// Sandbox-crossing, payload-free Darwin notification — the File Provider
// reconnect doorbell (#460).
//
// A File Provider extension can neither initiate an XPC connection to nor launch
// its owner on macOS, so when the extension has no live owner connection at
// `fetchContents` it *posts* the doorbell; the owner *observes* it and
// re-establishes the servicing control connection. Darwin notifications are a
// flat global namespace that crosses the sandbox boundary and carry no payload
// (name only) — and, unlike Mach service names, need no app-group prefix.
// `DistributedNotificationCenter` (Apple's FruitBasket sample's server→app
// signal) is sandbox-restricted for posting, so the CoreFoundation Darwin notify
// center is the sandbox-safe analogue.
//
// `notify_post`/`notify_register_dispatch` (from `<notify.h>`) are NOT in this
// SDK's Swift module map, so the CoreFoundation Darwin API is used instead.

/// Posts a payload-free Darwin notification by name.
public enum DarwinNotification {
    /// Posts `name` to every registered observer across the sandbox boundary.
    public static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true)
    }
}

/// Observes a Darwin notification, invoking `handler` on `queue` for each post.
///
/// The registration lives for the observer's lifetime; `cancel()` (also run from
/// `deinit`) removes it. Keep the observer retained for as long as posts should
/// be delivered — the CoreFoundation callback holds an *unretained* pointer to
/// `self`, so it must be cancelled (which `deinit` does) before `self` is freed.
///
/// `@unchecked Sendable`: `handler`/`queue`/`name` are immutable after `init`.
public final class DarwinNotificationObserver: @unchecked Sendable {
    private let name: String
    private let queue: DispatchQueue
    private let handler: @Sendable () -> Void

    /// Registers for `name`, delivering each post to `handler` on `queue`.
    public init(name: String, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        self.name = name
        self.queue = queue
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                // Unretained: valid because `cancel()` (deinit) removes the
                // observer before `self` is freed.
                let this = Unmanaged<DarwinNotificationObserver>.fromOpaque(observer)
                    .takeUnretainedValue()
                this.queue.async { this.handler() }
            },
            name as CFString,
            nil,
            .deliverImmediately)
    }

    /// Removes the registration.
    ///
    /// Idempotent — a second remove is a no-op.
    public func cancel() {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString),
            nil)
    }

    deinit { cancel() }
}
