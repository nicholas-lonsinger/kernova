import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("DetailRoute Tests", .admissionGated)
@MainActor
struct DetailRouteTests {
    /// A stand-in session identity for the live phases, which no CI test host
    /// can create a `VZVirtualMachine` for.
    private static let session = UUID()

    // MARK: - Editable settings

    @Test("Stopped routes to editable settings")
    func stoppedIsEditableSettings() {
        let route = DetailRoute.resolve(
            phase: .stopped,
            hasSetupState: false,
            detailPaneMode: .display
        )
        #expect(route == .settings(isReadOnly: false))
    }

    @Test("A failure routes to the error banner carrying its own message")
    func failureRoutesToErrorBanner() {
        let route = DetailRoute.resolve(
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
            phase: .operating(.bringUp(.settingUp(.macOSInstall)), from: .initialBoot),
            hasSetupState: true,
            detailPaneMode: .display
        )
        #expect(route == .setup)
    }

    @Test("Installing without a setup state routes to a transition")
    func installingWithoutStateRoutesToTransition() {
        let route = DetailRoute.resolve(
            phase: .operating(.bringUp(.settingUp(.macOSInstall)), from: .initialBoot),
            hasSetupState: false,
            detailPaneMode: .display
        )
        #expect(route == .transition(label: VMStatus.installing.displayName))
    }

    // MARK: - Active display honors the chosen pane

    @Test("Phases with a live display honor the chosen pane")
    func activeDisplayHonorsPane() {
        let live = VMLifecyclePhase.running(sessionID: Self.session)
        for phase in [
            live, .livePaused(sessionID: Self.session), .operating(.saving, from: live),
            .operating(.capturingSnapshot(.live), from: live),
            .operating(.bringUp(.restoringSavedState), from: .suspended, boundSession: Self.session),
        ] {
            let display = DetailRoute.resolve(
                phase: phase,
                hasSetupState: false,
                detailPaneMode: .display
            )
            #expect(display == .display, "\(phase)")

            let settings = DetailRoute.resolve(
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
                phase: .operating(
                    .bringUp(.starting(recovery: false)), from: .stopped,
                    boundSession: Self.session),
                hasSetupState: false,
                detailPaneMode: paneMode
            )
            #expect(route == .transition(label: VMStatus.starting.displayName))
        }
    }

    @Test("A session-less transition routes to its spinner, not the display pane")
    func sessionLessTransitionsRouteToTransition() {
        // A revert ends the session before it copies, and a disks-only capture
        // never had one — both would otherwise replace the Settings form with
        // the display backing view for the whole copy.
        for phase in [
            VMLifecyclePhase.operating(.capturingSnapshot(.stopped), from: .stopped),
            .operating(
                .bringUp(.reverting(snapshotID: Self.session, resumesAfter: false)),
                from: .running(sessionID: Self.session), sessionEnd: .endedByOperation),
            .operating(.bringUp(.restoringSavedState), from: .suspended),
        ] {
            for paneMode in [DetailPaneMode.display, .settings] {
                let route = DetailRoute.resolve(
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

    // MARK: - Base-status operations

    /// An operation that shows no status of its own routes as the phase it
    /// presents: the one it started from, or the rest its ended session names.
    @Test("A base-status operation routes as the phase it presents")
    func baseStatusOperationsRouteAsTheirPresentedPhase() {
        let live = VMLifecyclePhase.running(sessionID: Self.session)
        let editable = (DetailRoute.settings(isReadOnly: false), DetailRoute.settings(isReadOnly: false))
        let displayed = (DetailRoute.display, DetailRoute.settings(isReadOnly: true))
        let cases: [(VMLifecyclePhase, (display: DetailRoute, settings: DetailRoute))] = [
            (.operating(.deletingSnapshot, from: .stopped), editable),
            (.operating(.deleting, from: .stopped), editable),
            (.operating(.copyingOut, from: .stopped), editable),
            (
                .operating(.deletingSnapshot, from: .failed(message: "Boot failed.")),
                (.error(message: "Boot failed."), .error(message: "Boot failed."))
            ),
            (.operating(.deletingSnapshot, from: .initialBoot), (.initialBoot, .initialBoot)),
            (.operating(.discardingSavedState, from: .suspended), displayed),
            (.operating(.attachingUSB(registryID: 1), from: live), displayed),
            (.operating(.reconcilingMedia, from: live), displayed),
            (.operating(.forceStopping, from: live), displayed),
            (.operating(.resuming, from: .livePaused(sessionID: Self.session)), displayed),
            // The session ended under the operation: it presents the rest.
            (.operating(.pausing, from: live, sessionEnd: .poweredOff), editable),
            (
                .operating(.pausing, from: live, sessionEnd: .stoppedWithError(message: "Crashed.")),
                (.error(message: "Crashed."), .error(message: "Crashed."))
            ),
        ]
        for (phase, expected) in cases {
            let display = DetailRoute.resolve(
                phase: phase, hasSetupState: false, detailPaneMode: .display)
            let settings = DetailRoute.resolve(
                phase: phase, hasSetupState: false, detailPaneMode: .settings)
            #expect(display == expected.display, "\(phase)")
            #expect(settings == expected.settings, "\(phase)")
        }
    }

    @Test("A suspended VM keeps the display pane — it is settled, not transitioning")
    func suspendedKeepsTheDisplayPane() {
        let display = DetailRoute.resolve(
            phase: .suspended,
            hasSetupState: false,
            detailPaneMode: .display
        )
        #expect(display == .display)

        let settings = DetailRoute.resolve(
            phase: .suspended,
            hasSetupState: false,
            detailPaneMode: .settings
        )
        #expect(settings == .settings(isReadOnly: true))
    }
}
