import Foundation
import Testing

@testable import Kernova

@Suite("DetailRoute Tests", .admissionGated)
struct DetailRouteTests {
    /// A stand-in session identity for the live phases, which no CI test host
    /// can create a `VZVirtualMachine` for.
    private static let session = UUID()

    // MARK: - Preparing wins over everything

    @Test("A preparing label routes to .preparing regardless of phase")
    func preparingWins() {
        for phase in [
            VMLifecyclePhase.stopped, .running(sessionID: Self.session),
            .installing(sessionID: Self.session), .initialBoot, .failed(message: "Boot failed."),
        ] {
            let route = DetailRoute.resolve(
                preparingLabel: "Cloning…",
                phase: phase,
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
            phase: .stopped,
            hasSetupState: false,
            detailPaneMode: .display
        )
        #expect(route == .settings(isReadOnly: false))
    }

    @Test("A failure routes to the error banner carrying its own message")
    func failureRoutesToErrorBanner() {
        let route = DetailRoute.resolve(
            preparingLabel: nil,
            phase: .failed(message: "Boot failed."),
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
            phase: .initialBoot,
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
            phase: .installing(sessionID: Self.session),
            hasSetupState: true,
            detailPaneMode: .display
        )
        #expect(route == .setup)
    }

    @Test("Installing without a setup state routes to a transition")
    func installingWithoutStateRoutesToTransition() {
        let route = DetailRoute.resolve(
            preparingLabel: nil,
            phase: .installing(sessionID: Self.session),
            hasSetupState: false,
            detailPaneMode: .display
        )
        #expect(route == .transition(label: VMStatus.installing.displayName))
    }

    // MARK: - Active display honors the chosen pane

    @Test("Phases with a live display honor the chosen pane")
    func activeDisplayHonorsPane() {
        for phase in [
            VMLifecyclePhase.running(sessionID: Self.session),
            .livePaused(sessionID: Self.session), .saving(sessionID: Self.session),
            .capturingLive(sessionID: Self.session),
            .restoringSavedState(sessionID: Self.session),
        ] {
            let display = DetailRoute.resolve(
                preparingLabel: nil,
                phase: phase,
                hasSetupState: false,
                detailPaneMode: .display
            )
            #expect(display == .display, "\(phase)")

            let settings = DetailRoute.resolve(
                preparingLabel: nil,
                phase: phase,
                hasSetupState: false,
                detailPaneMode: .settings
            )
            #expect(settings == .settings(isReadOnly: true), "\(phase)")
        }
    }

    // MARK: - Transient phases

    @Test("Starting routes to a transition with the status label")
    func startingRoutesToTransition() {
        for paneMode in [DetailPaneMode.display, .settings] {
            let route = DetailRoute.resolve(
                preparingLabel: nil,
                phase: .starting(sessionID: Self.session),
                hasSetupState: false,
                detailPaneMode: paneMode
            )
            #expect(route == .transition(label: VMStatus.starting.displayName))
        }
    }

    @Test("A session-less transition routes to its spinner, not the display pane")
    func sessionLessTransitionsRouteToTransition() {
        // A revert always tears the session down before `.revertingToSnapshot`,
        // and a disks-only capture never had one — both would otherwise replace
        // the Settings form with the display backing view for the whole copy.
        for phase in [
            VMLifecyclePhase.capturingAtRest, .revertingToSnapshot,
            .restoringSavedState(sessionID: nil),
        ] {
            for paneMode in [DetailPaneMode.display, .settings] {
                let route = DetailRoute.resolve(
                    preparingLabel: nil,
                    phase: phase,
                    hasSetupState: false,
                    detailPaneMode: paneMode
                )
                #expect(
                    route == .transition(label: phase.status.displayName),
                    "phase \(phase), pane \(paneMode)")
            }
        }
    }

    @Test("A suspended VM keeps the display pane — it is settled, not transitioning")
    func suspendedKeepsTheDisplayPane() {
        let display = DetailRoute.resolve(
            preparingLabel: nil,
            phase: .suspended,
            hasSetupState: false,
            detailPaneMode: .display
        )
        #expect(display == .display)

        let settings = DetailRoute.resolve(
            preparingLabel: nil,
            phase: .suspended,
            hasSetupState: false,
            detailPaneMode: .settings
        )
        #expect(settings == .settings(isReadOnly: true))
    }
}
