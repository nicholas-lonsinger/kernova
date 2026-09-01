import AppKit
import Testing

@testable import Kernova

/// Unit tests for `AppResidencyController.windowCloseAffectsActivationPolicy(_:)`
/// — the pure
/// classifier the global `willClose` observer uses to decide whether a closing
/// window can change what `hasVisibleUserWindow` returns, so the close must run
/// the activation-policy reconcile.
///
/// Regression coverage for the status-item summon race: the dismissing status
/// menu's borderless window closes before the menu action fires, and letting it
/// run the reconcile flipped the app back to `.accessory` mid-summon, leaving
/// the summoned app last in the ⌘-Tab switcher.
@Suite("AppResidencyController.windowCloseAffectsActivationPolicy", .serialized, .admissionGated)
@MainActor
struct AppResidencyWindowCloseTests {
    @Test("A titled window's close runs the reconcile")
    func titledWindow() {
        let window = makeTestWindow(styleMask: [.titled, .closable])
        defer { window.close() }

        #expect(AppResidencyController.windowCloseAffectsActivationPolicy(window))
    }

    @Test("A borderless window's close does not run the reconcile")
    func borderlessWindow() {
        let window = makeTestWindow(styleMask: [.borderless])
        defer { window.close() }

        #expect(!AppResidencyController.windowCloseAffectsActivationPolicy(window))
    }
}
