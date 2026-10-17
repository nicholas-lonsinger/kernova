import AppKit
import KernovaKit
import Testing

@testable import KernovaCore
@testable import KernovaUI

/// Covers the summon an in-app click runs —
/// ``AppResidencyController/summonUserInterface()`` — and the reopen leg —
/// ``AppResidencyController/handleReopen()`` — against an ``AppPresence`` that
/// records its calls instead of unhiding or activating the test host.
///
/// No reopen here asserts a library show: the presence read scans
/// `NSApp.windows`, which also holds the windows of every test running
/// alongside this one, so only the no-show outcome is deterministic;
/// `AppResidencyReopenPresentationTests` pins the decision itself.
///
/// The controller is exercised without ``AppResidencyController/start(provenance:)``,
/// for the reason `AppResidencyPresentationTests` gives.
@Suite("AppResidencyController summon", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct AppResidencySummonTests {
    private let preferences = makeTestPreferences()

    /// Stands in for `NSApp`'s hidden state and activation, recording each
    /// unhide and activation in order.
    @MainActor
    private final class RecordingForeground: AppPresence {
        enum Step: Equatable {
            case unhide
            case activate(libraryOnScreen: Bool)
            /// A main-actor job the unhide enqueued has run.
            case laterJob
        }

        var activationPolicy = NSApplication.ActivationPolicy.regular
        let isActive = false
        /// Held across an unhide, so every presentation that would unhide
        /// records its own.
        let isHidden: Bool
        private(set) var steps: [Step] = []
        let gate = AsyncGate()
        /// Runs inside the unhide call, where AppKit could deliver
        /// `applicationDidUnhide` at the earliest.
        var onUnhide: () -> Void = {}
        weak var registry: AppWindowRegistry?

        init(isHidden: Bool) { self.isHidden = isHidden }

        func record(_ step: Step) {
            steps.append(step)
            gate.notify()
        }

        var activations: Int {
            steps.filter { if case .activate = $0 { true } else { false } }.count
        }

        func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
            activationPolicy = policy
        }

        func unhideWithoutActivation() {
            record(.unhide)
            onUnhide()
        }

        func activate() {
            record(.activate(libraryOnScreen: registry?.libraryWindow?.isVisible == true))
        }
    }

    /// Counts the windows the registry puts up, standing in for the residency
    /// that answers ``WindowResidencyHosting/prepareToPresentWindow()``.
    private final class PresentationCounter: WindowResidencyHosting {
        private(set) var count = 0
        let guiPosture = GUIPosture.foreground

        func prepareToPresentWindow() { count += 1 }
        func syncActivationPolicy() {}
    }

    private func makeController(
        foreground: RecordingForeground
    ) -> (AppResidencyController, AppWindowRegistry, VMLibraryViewModel) {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        let registry = makeWindowRegistry(viewModel)
        foreground.registry = registry
        let controller = AppResidencyController(
            viewModel: viewModel, windows: registry, heldAlerts: HeldAlerts(),
            presence: foreground)
        return (controller, registry, viewModel)
    }

    @Test("A summon asks for activation once, after its surface is on screen")
    func summonActivatesAfterOrderFront() async throws {
        let foreground = RecordingForeground(isHidden: false)
        let (controller, _, _) = makeController(foreground: foreground)

        controller.summonUserInterface()
        try await foreground.gate.wait { foreground.activations > 0 }

        #expect(foreground.steps == [.activate(libraryOnScreen: true)])
    }

    @Test("A hidden summon unhides, shows and activates in one main-actor job")
    func hiddenSummonIsOneJob() async throws {
        let foreground = RecordingForeground(isHidden: true)
        foreground.onUnhide = { [foreground] in
            Task { @MainActor in foreground.record(.laterJob) }
        }
        let (controller, _, _) = makeController(foreground: foreground)

        controller.summonUserInterface()
        // The unhide belongs to the deferred show, never to the call itself.
        #expect(foreground.steps.isEmpty)
        try await foreground.gate.wait { foreground.steps.contains(.laterJob) }

        #expect(foreground.steps == [.unhide, .activate(libraryOnScreen: true), .laterJob])
    }

    @Test("A delivered presentation neither unhides nor asks for activation")
    func deliveredPresentationAsksNothing() async throws {
        let foreground = RecordingForeground(isHidden: true)
        let (controller, registry, _) = makeController(foreground: foreground)
        registry.showLibrary(bringToFront: true)

        // The summon's job runs behind the delivered one, so once the summon has
        // asked, anything the delivered one did is recorded ahead of it — and
        // the fake stays hidden, so an unhide by both would record two.
        controller.presentSummonedInterface()
        controller.summonUserInterface()
        try await foreground.gate.wait { foreground.activations > 0 }

        #expect(foreground.steps == [.unhide, .activate(libraryOnScreen: true)])
    }

    @Test("A status-item row for an arrival selects it and summons the library")
    func arrivalRowSelectsTheArrival() async throws {
        let foreground = RecordingForeground(isHidden: false)
        let (controller, _, viewModel) = makeController(foreground: foreground)
        let arrival = VMArrival.inert(
            .importing,
            configuration: VMConfiguration(
                name: "Arriving", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize))
        viewModel.library.register(arrival)
        viewModel.selection = nil

        controller.summonStatusItemTarget(for: arrival.id)
        try await foreground.gate.wait { foreground.activations > 0 }

        #expect(viewModel.selectedID == arrival.id)
        #expect(foreground.steps == [.activate(libraryOnScreen: true)])
    }

    @Test("A reopen while hidden leaves the hidden state before it decides")
    func hiddenReopenUnhidesBeforeDeciding() async throws {
        let foreground = RecordingForeground(isHidden: true)
        let (controller, registry, _) = makeController(foreground: foreground)
        registry.showLibrary(bringToFront: true)
        let library = try #require(registry.libraryWindow)
        // A hidden app's windows read `isVisible == false` until the unhide
        // brings them back.
        library.orderOut(nil)
        foreground.onUnhide = { [foreground] in
            library.orderFront(nil)
            Task { @MainActor in foreground.record(.laterJob) }
        }
        let presentations = PresentationCounter()
        registry.residency = presentations

        controller.handleReopen()
        // The unhide belongs to the deferred decision, never to the call itself.
        #expect(foreground.steps.isEmpty)
        try await foreground.gate.wait { foreground.steps.contains(.laterJob) }

        #expect(foreground.steps == [.unhide, .laterJob])
        #expect(presentations.count == 0)
    }

    @Test("A reopen whose only user window is miniaturized shows no library")
    func miniaturizedWindowOwnsTheReopen() async throws {
        let foreground = RecordingForeground(isHidden: false)
        let (controller, registry, _) = makeController(foreground: foreground)
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
        let presentations = PresentationCounter()
        registry.residency = presentations

        controller.handleReopen()
        // Enqueued behind the reopen's job, so it records once that job has run.
        Task { @MainActor in foreground.record(.laterJob) }
        try await foreground.gate.wait { foreground.steps.contains(.laterJob) }

        #expect(presentations.count == 0)
        #expect(foreground.steps == [.laterJob])
    }
}
