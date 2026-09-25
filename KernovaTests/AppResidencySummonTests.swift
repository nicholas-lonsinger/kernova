import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Covers the summon an in-app click runs —
/// ``AppResidencyController/summonUserInterface()`` — against a
/// ``AppResidencyController/ForegroundControl`` that records its calls instead
/// of hiding, unhiding or activating the test host.
///
/// The controller is exercised without ``AppResidencyController/start(provenance:)``,
/// for the reason `AppResidencyPresentationTests` gives.
@Suite("AppResidencyController summon", .serialized, .admissionGated, .scopedWindows)
@MainActor
struct AppResidencySummonTests {
    private let preferences = makeTestPreferences()
    private let autosave = WindowAutosaveScope.unsaved()

    /// Stands in for `NSApp`'s hidden state and activation, recording each call
    /// in order.
    @MainActor
    private final class RecordingForeground {
        enum Step: Equatable {
            case unhide
            case activate(libraryOnScreen: Bool)
            /// A main-actor job the unhide enqueued has run.
            case laterJob
        }

        var isHidden: Bool
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

        var control: AppResidencyController.ForegroundControl {
            AppResidencyController.ForegroundControl(
                isHidden: { [self] in isHidden },
                unhideWithoutActivation: { [self] in
                    isHidden = false
                    record(.unhide)
                    onUnhide()
                },
                activate: { [self] in
                    // The same main-actor job ordered the summoned window in, so
                    // adopting it here keeps it from ever being drawn.
                    let window = registry?.libraryWindow
                    if let window { adoptAppWindow(window) }
                    record(.activate(libraryOnScreen: window?.isVisible == true))
                })
        }
    }

    private func makeController(
        foreground: RecordingForeground
    ) -> (AppResidencyController, AppWindowRegistry, VMLibraryViewModel) {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        let registry = AppWindowRegistry(
            viewModel: viewModel,
            displayPlacement: VMDisplayPlacementController(viewModel: viewModel, autosaveScope: autosave),
            autosaveScope: autosave)
        foreground.registry = registry
        let controller = AppResidencyController(
            viewModel: viewModel, windows: registry, foreground: foreground.control)
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

    @Test("The reconcile a summon's unhide sets off finds the summoned surface on screen")
    func summonUnhideReconcileSeesTheSurface() async throws {
        let foreground = RecordingForeground(isHidden: true)
        let (controller, _, viewModel) = makeController(foreground: foreground)
        // A reconcile reading an empty window list would then answer
        // `.presentLibrary`, rather than dropping the test host to `.accessory`.
        viewModel.keepInMenuBarOnQuit = false
        foreground.onUnhide = { [weak controller] in controller?.noteDidUnhide() }

        controller.summonUserInterface()
        try await foreground.gate.wait { foreground.activations > 0 }

        let reconcile = try #require(controller.pendingUnhideReconcileForTesting)
        #expect(await reconcile.value == .showDockIcon)
    }

    @Test("A delivered presentation neither unhides nor asks for activation")
    func deliveredPresentationAsksNothing() async throws {
        let foreground = RecordingForeground(isHidden: true)
        let (controller, registry, _) = makeController(foreground: foreground)
        registry.showLibrary(bringToFront: true)
        adoptAppWindow(try #require(registry.libraryWindow))

        // The summon's job runs behind the delivered one, so once the summon has
        // asked, anything the delivered one did is recorded ahead of it.
        controller.presentSummonedInterface()
        controller.summonUserInterface()
        try await foreground.gate.wait { foreground.activations > 0 }

        #expect(foreground.steps == [.unhide, .activate(libraryOnScreen: true)])
    }
}
