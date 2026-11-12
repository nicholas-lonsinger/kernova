import AppKit
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// Covers the summon an in-app click runs —
/// ``AppResidencyController/summonUserInterface()`` — and the reopen leg —
/// ``AppResidencyController/handleReopen()`` — against a ``SessionFocus`` that
/// records its requests instead of unhiding or activating the test host.
///
/// The controller is exercised without ``AppResidencyController/start(provenance:)``,
/// for the reason `AppResidencyPresentationTests` gives.
@Suite("AppResidencyController summon", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct AppResidencySummonTests {
    private let preferences = makeTestPreferences()

    /// Counts the windows the registry puts up, standing in for the residency
    /// that answers ``WindowResidencyHosting/prepareToPresentWindow()``.
    private final class PresentationCounter: WindowResidencyHosting {
        private(set) var count = 0
        let guiPosture = GUIPosture.foreground

        func prepareToPresentWindow() { count += 1 }
        func syncActivationPolicy() {}
    }

    /// A main-actor job enqueued from inside the one under test, so it runs
    /// once that job has ended: what it finds recorded is everything that job
    /// asked for.
    @MainActor
    private final class LaterJob {
        private(set) var requestsSeen: [RecordingSessionFocus.Request]?
        let gate = AsyncGate()

        func enqueue(reading focus: RecordingSessionFocus) {
            Task { @MainActor in
                self.requestsSeen = focus.requests
                self.gate.notify()
            }
        }
    }

    private func makeController(
        focus: RecordingSessionFocus
    ) -> (AppResidencyController, AppWindowRegistry, VMLibraryViewModel) {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        let registry = makeWindowRegistry(viewModel, focus: focus)
        let controller = AppResidencyController(
            viewModel: viewModel, windows: registry, heldAlerts: HeldAlerts(), focus: focus)
        return (controller, registry, viewModel)
    }

    @Test("A hidden summon unhides, shows and activates in one main-actor job")
    func hiddenSummonIsOneJob() async throws {
        let focus = RecordingSessionFocus(isHidden: true)
        let (controller, registry, _) = makeController(focus: focus)
        let laterJob = LaterJob()
        focus.onRequest = { [focus] request in
            if request == .unhideWithoutActivation { laterJob.enqueue(reading: focus) }
        }

        controller.summonUserInterface()
        // The unhide belongs to the deferred show, never to the call itself.
        #expect(focus.requests.isEmpty)
        try await laterJob.gate.wait { laterJob.requestsSeen != nil }

        let library = try #require(registry.libraryWindow)
        #expect(
            laterJob.requestsSeen == [
                .unhideWithoutActivation, .present(library, .keyAndFront), .present(library, .frontRegardless),
                .activate, .cancelMenuBarTracking,
            ])
    }

    @Test("A delivered presentation neither unhides nor asks for activation")
    func deliveredPresentationAsksNothing() async throws {
        let focus = RecordingSessionFocus(isHidden: true)
        let (controller, registry, _) = makeController(focus: focus)
        registry.showLibrary(bringToFront: true)
        let library = try #require(registry.libraryWindow)
        let shown: [RecordingSessionFocus.Request] = [
            .present(library, .keyAndFront), .present(library, .frontRegardless),
        ]

        // The summon's job runs behind the delivered one, so once the summon has
        // asked, anything the delivered one did is recorded ahead of it — and
        // the fake stays hidden, so an unhide by both would record two.
        controller.presentSummonedInterface()
        controller.summonUserInterface()
        try await focus.gate.wait {
            focus.requests.last == .cancelMenuBarTracking && focus.requests.contains(.activate)
        }

        #expect(
            focus.requests == [.present(library, .keyAndFront)] + shown + [.cancelMenuBarTracking]
                + [.unhideWithoutActivation] + shown + [.activate, .cancelMenuBarTracking])
    }

    @Test("A status-item row for an arrival selects it and summons the library")
    func arrivalRowSelectsTheArrival() async throws {
        let focus = RecordingSessionFocus(isHidden: false)
        let (controller, registry, viewModel) = makeController(focus: focus)
        let arrival = VMArrival.inert(
            .importing,
            configuration: VMConfiguration(
                name: "Arriving", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize))
        viewModel.library.register(arrival)
        viewModel.selection = nil

        controller.summonStatusItemTarget(for: arrival.id)
        try await focus.gate.wait { focus.requests.last == .cancelMenuBarTracking }

        #expect(viewModel.selectedID == arrival.id)
        let library = try #require(registry.libraryWindow)
        #expect(
            focus.requests == [
                .present(library, .keyAndFront), .present(library, .frontRegardless), .activate,
                .cancelMenuBarTracking,
            ])
    }

    @Test("A reopen with no user window on screen shows the library")
    func windowlessReopenShowsTheLibrary() async throws {
        let focus = RecordingSessionFocus(isHidden: false)
        let (controller, registry, _) = makeController(focus: focus)
        let presentations = PresentationCounter()
        registry.residency = presentations

        controller.handleReopen()
        // The reopen's job is already queued, so it runs ahead of the barrier.
        await drainMainQueue()

        #expect(presentations.count == 1)
        let library = try #require(registry.libraryWindow)
        #expect(focus.requests == [.present(library, .keyAndFront), .present(library, .frontRegardless)])
    }

    @Test("A reopen while hidden leaves the hidden state before it decides")
    func hiddenReopenUnhidesBeforeDeciding() async throws {
        let focus = RecordingSessionFocus(isHidden: true)
        let (controller, registry, _) = makeController(focus: focus)
        registry.showLibrary(bringToFront: true)
        let library = try #require(registry.libraryWindow)
        // A hidden app's windows read `isVisible == false` until the unhide
        // brings them back.
        library.orderOut(nil)
        let requestsBefore = focus.requests
        focus.onRequest = { request in
            if request == .unhideWithoutActivation { library.orderFront(nil) }
        }
        let presentations = PresentationCounter()
        registry.residency = presentations

        controller.handleReopen()
        // The unhide belongs to the deferred decision, never to the call itself.
        #expect(focus.requests == requestsBefore)
        await drainMainQueue()

        #expect(focus.requests == requestsBefore + [.unhideWithoutActivation])
        #expect(presentations.count == 0)
    }

    @Test("A reopen whose only user window is miniaturized shows no library")
    func miniaturizedWindowOwnsTheReopen() async throws {
        let focus = RecordingSessionFocus(isHidden: false)
        let (controller, registry, _) = makeController(focus: focus)
        registry.showLibrary(bringToFront: true)
        let library = try #require(registry.libraryWindow)
        // AppKit reports the miniaturize a runloop turn later, through the
        // notification the wait is driven by.
        let miniaturized = AsyncGate()
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: library, queue: .main
        ) { _ in miniaturized.notify() }
        defer { NotificationCenter.default.removeObserver(observer) }
        library.miniaturize(nil)
        try await miniaturized.wait { library.isMiniaturized && !library.isVisible }
        let requestsBefore = focus.requests
        let presentations = PresentationCounter()
        registry.residency = presentations

        controller.handleReopen()
        // The reopen's job is already queued, so it runs ahead of the barrier.
        await drainMainQueue()

        #expect(presentations.count == 0)
        #expect(focus.requests == requestsBefore)
    }
}
