import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Whether the detail pane's settings form takes edits: the catalog's answer
/// for every route that shows the form, and no reading at all for a route
/// that does not.
@Suite("Detail router read-only form", .serialized, .caseScoped)
@MainActor
struct VMDetailRouterReadOnlyTests {
    private let preferences = makeTestPreferences()

    /// A router shown for a VM resting at `phase`, marked held by another copy
    /// of Kernova when `heldByAnotherCopy`.
    private func showRouter(
        _ phase: VMLifecyclePhase, heldByAnotherCopy: Bool,
        paneMode: DetailPaneMode = .display
    ) -> VMDetailRouterViewController {
        let viewModel = makeSettingsViewModel(preferences: preferences)
        let instance = viewModel.library.registerFixture(phase: phase)
        instance.detailPaneMode = paneMode
        if heldByAnotherCopy { instance.activity.recordOtherCopyHold(heldElsewhere: true) }
        let router = VMDetailRouterViewController(instance: instance, viewModel: viewModel)
        router.loadViewIfNeeded()
        router.viewDidAppear()
        return router
    }

    nonisolated private static let formPhases: [VMLifecyclePhase] = [
        .stopped, .initialBoot, .failed(message: "Boot failed."),
    ]

    @Test(
        "Every route showing the form holds it read-only exactly while another copy holds the VM",
        arguments: formPhases)
    func formFollowsTheCatalog(phase: VMLifecyclePhase) throws {
        for held in [false, true] {
            let router = showRouter(phase, heldByAnotherCopy: held)
            let rendered = try #require(router.renderedForTesting)
            #expect(rendered.isReadOnly == held, "\(phase) held=\(held)")
            #expect(router.settingsForTesting.isReadOnlyForTesting == held, "\(phase) held=\(held)")
        }
    }

    @Test("A route with no form reads no lock, while the same VM's form reads it locked")
    func displayRouteReadsNoLock() throws {
        let display = showRouter(.suspended, heldByAnotherCopy: true)
        let shown = try #require(display.renderedForTesting)
        #expect(shown.route == .display)
        #expect(!shown.isReadOnly)

        let form = showRouter(.suspended, heldByAnotherCopy: true, paneMode: .settings)
        let settings = try #require(form.renderedForTesting)
        #expect(settings.route == .settings)
        #expect(settings.isReadOnly)
        #expect(form.settingsForTesting.isReadOnlyForTesting)
    }
}
