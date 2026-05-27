import Testing
@testable import Kernova

@Suite("DetailRoute Tests")
struct DetailRouteTests {
    // MARK: - Preparing wins over everything

    @Test("A preparing label routes to .preparing regardless of status")
    func preparingWins() {
        for status in [VMStatus.stopped, .running, .installing, .initialBoot, .error] {
            let route = DetailRoute.resolve(
                preparingLabel: "Cloning…",
                status: status,
                hasInstallState: true,
                detailPaneMode: .display
            )
            #expect(route == .preparing(label: "Cloning…"))
        }
    }

    // MARK: - Editable settings

    @Test("Stopped and error route to editable settings")
    func stoppedAndErrorAreEditableSettings() {
        for status in [VMStatus.stopped, .error] {
            let route = DetailRoute.resolve(
                preparingLabel: nil,
                status: status,
                hasInstallState: false,
                detailPaneMode: .display
            )
            #expect(route == .settings(isReadOnly: false))
        }
    }

    @Test("Initial boot routes to .initialBoot")
    func initialBootRoute() {
        let route = DetailRoute.resolve(
            preparingLabel: nil,
            status: .initialBoot,
            hasInstallState: false,
            detailPaneMode: .display
        )
        #expect(route == .initialBoot)
    }

    // MARK: - Installing

    @Test("Installing with an install state routes to .install")
    func installingWithStateRoutesToInstall() {
        let route = DetailRoute.resolve(
            preparingLabel: nil,
            status: .installing,
            hasInstallState: true,
            detailPaneMode: .display
        )
        #expect(route == .install)
    }

    @Test("Installing without an install state routes to a transition")
    func installingWithoutStateRoutesToTransition() {
        let route = DetailRoute.resolve(
            preparingLabel: nil,
            status: .installing,
            hasInstallState: false,
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
                hasInstallState: false,
                detailPaneMode: .display
            )
            #expect(display == .display)

            let settings = DetailRoute.resolve(
                preparingLabel: nil,
                status: status,
                hasInstallState: false,
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
                hasInstallState: false,
                detailPaneMode: paneMode
            )
            #expect(route == .transition(label: VMStatus.starting.displayName))
        }
    }
}
