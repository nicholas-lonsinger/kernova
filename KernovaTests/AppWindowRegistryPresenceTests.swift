import AppKit
import Testing

@testable import KernovaCore
@testable import KernovaUI

/// Covers `AppWindowRegistry.hasTrackedUserWindow` — the deterministic half
/// of the window-presence answer the activation-policy reconcile and the reopen
/// leg both read — the clipboard window's close-driven deregistration, and the
/// `WindowResidencyHosting` call a presentation owes.
///
/// Only the tracked windows are exercised for presence: the `NSApp.windows` scan
/// `hasUserWindow` layers on top also sees the windows of every test running
/// alongside this one in the shared test host, so it has no deterministic
/// answer here.
@Suite("AppWindowRegistry presence", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct AppWindowRegistryPresenceTests {
    private let preferences = makeTestPreferences()

    /// Records the residency calls the registry makes, standing in for the
    /// controller that answers them in the resident app.
    private final class StubResidencyHost: WindowResidencyHosting {
        var prepareCount = 0
        var syncCount = 0
        var guiPosture = GUIPosture.foreground

        func prepareToPresentWindow() { prepareCount += 1 }
        func syncActivationPolicy() { syncCount += 1 }
    }

    private func makeRegistry(presence: TestAppPresence = TestAppPresence()) -> AppWindowRegistry {
        makeWindowRegistry(makeLibraryViewModel(preferences: preferences), presence: presence)
    }

    /// A VM the clipboard window opens for: sharing on, and a live session, which
    /// is what `accepts(.showClipboard, on:)` asks for.
    private func makeClipboardEligibleInstance() -> VMInstance {
        VMInstanceFixture.make(name: "Clipboard VM", phase: .running(sessionID: UUID())) {
            $0.clipboardSharingEnabled = true
        }
    }

    @Test("A registry that has shown nothing tracks no on-screen window")
    func nothingShown() {
        let registry = makeRegistry()

        #expect(!registry.hasTrackedUserWindow)
    }

    @Test("The library window counts")
    func libraryShown() throws {
        let registry = makeRegistry()
        registry.showLibrary(bringToFront: true)

        #expect(registry.hasTrackedUserWindow)
    }

    @Test("A miniaturized library window counts")
    func libraryMiniaturized() async throws {
        let registry = makeRegistry()
        registry.showLibrary(bringToFront: true)
        let window = try #require(registry.libraryWindow)

        // AppKit reports the miniaturize a runloop turn later — the window is
        // still `isVisible` when `miniaturize(_:)` returns — so the wait is
        // driven by the notification that reports it.
        let gate = AsyncGate()
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main
        ) { _ in gate.notify() }
        defer { NotificationCenter.default.removeObserver(observer) }
        window.miniaturize(nil)
        try await gate.wait { window.isMiniaturized && !window.isVisible }

        #expect(registry.hasTrackedUserWindow)
    }

    @Test("The Settings window counts on its own")
    func settingsShown() throws {
        let registry = makeRegistry()
        registry.showSettings()

        #expect(registry.hasTrackedUserWindow)
    }

    @Test("An automatic config check shows its window without bringing Kernova forward; the user's does both")
    func configCheckActivatesOnlyForTheUser() throws {
        let presence = TestAppPresence()
        let registry = makeRegistry(presence: presence)

        registry.showConfigCheck(.automatic)
        let window = try #require(registry.configCheckWindow)
        #expect(window.isVisible)
        #expect(presence.requests.isEmpty)

        registry.showConfigCheck(.user)
        #expect(window.isVisible)
        #expect(presence.requests == [.activate])
    }

    @Test("Showing a clipboard window asks residency to prepare, and its close deregisters it")
    func clipboardWindowDrivesResidency() throws {
        let registry = makeRegistry()
        let host = StubResidencyHost()
        registry.residency = host
        let instance = makeClipboardEligibleInstance()

        registry.showClipboard(for: instance)
        let window = try #require(registry.clipboardWindow(for: instance.instanceID))

        #expect(host.prepareCount == 1)
        #expect(registry.hasTrackedUserWindow)

        // The close is answered by the registry's own deregistration; the
        // resident app's global `willClose` observer runs the reconcile, since
        // a clipboard window is titled.
        window.close()

        #expect(registry.clipboardWindow(for: instance.instanceID) == nil)
    }

    @Test("A VM whose state refuses the clipboard opens no window")
    func clipboardRefusedForIneligibleVM() {
        let registry = makeRegistry()
        let instance = VMInstanceFixture.make(name: "Stopped VM")

        registry.showClipboard(for: instance)

        #expect(registry.clipboardWindow(for: instance.instanceID) == nil)
    }
}
