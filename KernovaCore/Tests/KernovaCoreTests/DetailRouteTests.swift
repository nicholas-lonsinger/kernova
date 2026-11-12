import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("DetailRoute Tests", .caseScoped)
@MainActor
struct DetailRouteTests {
    /// A stand-in session identity for the live phases, which no CI test host
    /// can create a `VZVirtualMachine` for.
    private static let session = UUID()

    // MARK: - Installing

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
            .operating(.bringUp(.guestStart(.restoringSavedState)), from: .suspended, boundSession: Self.session),
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
            #expect(settings == .settings, "\(phase)")
        }
    }

    // MARK: - Base-status operations

    /// An operation that shows no status of its own routes as the phase it
    /// presents: the one it started from, or the rest its ended session names.
    @Test("A base-status operation routes as the phase it presents")
    func baseStatusOperationsRouteAsTheirPresentedPhase() {
        let live = VMLifecyclePhase.running(sessionID: Self.session)
        let form = (DetailRoute.settings, DetailRoute.settings)
        let displayed = (DetailRoute.display, DetailRoute.settings)
        let cases: [(VMLifecyclePhase, (display: DetailRoute, settings: DetailRoute))] = [
            (.operating(.deletingSnapshot, from: .stopped), form),
            (.operating(.deleting, from: .stopped), form),
            (.operating(.copyingOut(.stopped), from: .stopped), form),
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
            (.operating(.pausing, from: live, sessionEnd: .poweredOff), form),
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
}
