import Foundation
import Testing

@testable import KernovaKit

/// Contract tests for the File Provider reconnect doorbell.
///
/// Exercises `DarwinNotification` + `DarwinNotificationObserver` (#460). The
/// *delivery* round trip is intentionally not unit-tested here: CFNotificationCenter
/// delivers Darwin callbacks only on a running main run loop, which the KernovaKit
/// SwiftPM test target does not host, so a post→observe test would be
/// environment-dependent — the flaky-wait shape the project avoids. Delivery is
/// exercised end-to-end by the File Provider integration; these tests cover the
/// parts that ARE deterministic: the observer's `unretained-self` lifecycle / cancel
/// contract (the actually-risky code) and that posting is always safe.
@Suite struct DarwinNotificationTests {
    /// `cancel()` is idempotent — a second call is a documented no-op, not a crash.
    @Test func cancelIsIdempotent() {
        let observer = DarwinNotificationObserver(name: Self.uniqueName(), queue: .main) {}
        observer.cancel()
        observer.cancel()
    }

    /// An observer that is only ever deinitialized (never explicitly cancelled) tears
    /// down cleanly — `deinit` removes the registration whose C callback holds an
    /// unretained pointer to `self`, so the pointer can never outlive the object.
    @Test func deinitRemovesRegistration() {
        for _ in 0..<50 {
            _ = DarwinNotificationObserver(name: Self.uniqueName(), queue: .main) {}
        }
        // Reaching here without a crash exercises the init → deinit → cancel path
        // repeatedly, catching a use-after-free in the unretained-self teardown.
    }

    /// Posting a name with no live observer is a safe no-op.
    @Test func postWithoutObserverIsSafe() {
        DarwinNotification.post(Self.uniqueName())
    }

    private static func uniqueName() -> String {
        "app.kernova.test.doorbell.\(UUID().uuidString)"
    }
}
