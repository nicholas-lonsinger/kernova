import CoreFoundation
import Foundation

// Sandbox-crossing, payload-free Darwin notification — the File Provider
// reconnect doorbell.
//
// A File Provider extension can neither initiate an XPC connection to nor launch
// its owner, so it posts this doorbell and the owner re-establishes servicing.
// `DistributedNotificationCenter` is sandbox-restricted for posting, and
// `notify_post`/`notify_register_dispatch` (`<notify.h>`) are absent from this
// SDK's Swift module map, so the CoreFoundation Darwin notify center is used.

/// Posts a payload-free Darwin notification by name.
enum DarwinNotification {
    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true)
    }
}

/// Observes a Darwin notification, invoking `handler` on `queue` for each post.
///
/// Keep the observer retained for as long as posts should be delivered — the
/// CoreFoundation callback holds an *unretained* pointer to `self`, so the
/// registration must be cancelled (which `deinit` does) before `self` is freed.
final class DarwinNotificationObserver: @unchecked Sendable {
    private let name: String
    private let queue: DispatchQueue
    private let handler: @Sendable () -> Void

    init(name: String, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        self.name = name
        self.queue = queue
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let this = Unmanaged<DarwinNotificationObserver>.fromOpaque(observer)
                    .takeUnretainedValue()
                this.queue.async { this.handler() }
            },
            name as CFString,
            nil,
            .deliverImmediately)
    }

    /// Removes the registration; idempotent.
    func cancel() {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString),
            nil)
    }

    deinit { cancel() }
}
