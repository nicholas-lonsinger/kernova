import Testing
@testable import Kernova

@Suite("DetailRoute Tests", .admissionGated)
struct DetailRouteTests {
    // MARK: - Preparing wins over everything

    @Test("A preparing label routes to .preparing regardless of status")
    func preparingWins() {
        for status in [VMStatus.stopped, .running, .installing, .initialBoot, .error] {
            let route = DetailRoute.resolve(
                preparingLabel: "Cloning…",
                status: status,
                errorMessage: nil,
                hasSetupState: true,
                detailPaneMode: .display
            )
            #expect(route == .preparing(label: "Cloning…"))
        }
    }

    // MARK: - Editable settings

    @Test("Stopped routes to editable settings")
    func stoppedIsEditableSettings() {
        let route = DetailRoute.resolve(
            preparingLabel: nil,
            status: .stopped,
            errorMessage: nil,
            hasSetupState: false,
            detailPaneMode: .display
        )
        #expect(route == .settings(isReadOnly: false))
    }

    @Test("Error routes to the error banner carrying the stored message")
    func errorRoutesToErrorBanner() {
        let route = DetailRoute.resolve(
            preparingLabel: nil,
            status: .error,
            errorMessage: "Boot failed.",
            hasSetupState: false,
            detailPaneMode: .display
        )
        #expect(route == .error(message: "Boot failed."))
        // A second failure with different text must not compare equal to the first.
        #expect(route != .error(message: nil))
    }

    @Test("Initial boot routes to .initialBoot")
    func initialBootRoute() {
        let route = DetailRoute.resolve(
            preparingLabel: nil,
            status: .initialBoot,
            errorMessage: nil,
            hasSetupState: false,
            detailPaneMode: .display
        )
        #expect(route == .initialBoot)
    }

    // MARK: - Installing

    @Test("Installing with a setup state routes to .setup")
    func installingWithStateRoutesToSetup() {
        let route = DetailRoute.resolve(
            preparingLabel: nil,
            status: .installing,
            errorMessage: nil,
            hasSetupState: true,
            detailPaneMode: .display
        )
        #expect(route == .setup)
    }

    @Test("Installing without a setup state routes to a transition")
    func installingWithoutStateRoutesToTransition() {
        let route = DetailRoute.resolve(
            preparingLabel: nil,
            status: .installing,
            errorMessage: nil,
            hasSetupState: false,
            detailPaneMode: .display
        )
        #expect(route == .transition(label: VMStatus.installing.displayName))
    }

    // MARK: - Active display honors the chosen pane

    @Test("Active-display statuses honor the chosen pane")
    func activeDisplayHonorsPane() {
        for status in [VMStatus.running, .paused, .saving, .restoring] {
            let display = DetailRoute.resolve(
                preparingLabel: nil,
                status: status,
                errorMessage: nil,
                hasSetupState: false,
                detailPaneMode: .display
            )
            #expect(display == .display)

            let settings = DetailRoute.resolve(
                preparingLabel: nil,
                status: status,
                errorMessage: nil,
                hasSetupState: false,
                detailPaneMode: .settings
            )
            #expect(settings == .settings(isReadOnly: true))
        }
    }

    // MARK: - Transient statuses

    @Test("Starting routes to a transition with the status label")
    func startingRoutesToTransition() {
        for paneMode in [DetailPaneMode.display, .settings] {
            let route = DetailRoute.resolve(
                preparingLabel: nil,
                status: .starting,
                errorMessage: nil,
                hasSetupState: false,
                detailPaneMode: paneMode
            )
            #expect(route == .transition(label: VMStatus.starting.displayName))
        }
    }
}
