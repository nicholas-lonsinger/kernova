import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// Unit tests for `GuestAgentDiskMenuItem.model(status:isInstallerMounted:)` —
/// the single source of truth shared by `MainMenuController.validate` and
/// `toggleGuestAgentDisk`, so the menu title can never disagree with the action.
@Suite("GuestAgentDiskMenuItem.model", .admissionGated)
struct GuestAgentDiskMenuTests {
    @Test("Attached installer → eject mode, regardless of agent status")
    func attachedEjectsRegardlessOfStatus() {
        let statuses: [AgentStatus] = [
            .waiting,
            .outdated(installed: "0.9.0", bundled: "0.9.2"),
            .expectedMissing(expected: "0.9.0"),
            .current(version: "0.9.2"),
            .unresponsive(version: "0.9.2"),
            .connecting(expected: "0.9.2"),
        ]
        for status in statuses {
            #expect(
                GuestAgentDiskMenuItem.model(status: status, isInstallerMounted: true)
                    == .init(title: "Eject Guest Agent Media", isEnabled: true, action: .eject))
        }
    }

    @Test(".waiting → Install / enabled / mount(.install)")
    func waiting() {
        #expect(
            GuestAgentDiskMenuItem.model(status: .waiting, isInstallerMounted: false)
                == .init(title: "Install Guest Agent…", isEnabled: true, action: .mount(.install)))
    }

    @Test(".outdated → Update / enabled / mount(.install)")
    func outdated() {
        #expect(
            GuestAgentDiskMenuItem.model(
                status: .outdated(installed: "0.9.0", bundled: "0.9.2"), isInstallerMounted: false)
                == .init(title: "Update Guest Agent…", isEnabled: true, action: .mount(.install)))
    }

    @Test(".expectedMissing → Reinstall / enabled / mount(.install)")
    func expectedMissing() {
        #expect(
            GuestAgentDiskMenuItem.model(
                status: .expectedMissing(expected: "0.9.0"), isInstallerMounted: false)
                == .init(title: "Reinstall Guest Agent…", isEnabled: true, action: .mount(.install)))
    }

    @Test(".current → Manage / enabled / mount(.manage)")
    func current() {
        #expect(
            GuestAgentDiskMenuItem.model(status: .current(version: "0.9.2"), isInstallerMounted: false)
                == .init(title: "Manage Guest Agent…", isEnabled: true, action: .mount(.manage)))
    }

    @Test(".unresponsive → Manage / enabled / mount(.manage) — not reliably transient")
    func unresponsive() {
        #expect(
            GuestAgentDiskMenuItem.model(
                status: .unresponsive(version: "0.9.2"), isInstallerMounted: false)
                == .init(title: "Manage Guest Agent…", isEnabled: true, action: .mount(.manage)))
    }

    @Test(".connecting → Install / disabled / mount(.install) — transient")
    func connecting() {
        #expect(
            GuestAgentDiskMenuItem.model(
                status: .connecting(expected: "0.9.2"), isInstallerMounted: false)
                == .init(title: "Install Guest Agent…", isEnabled: false, action: .mount(.install)))
    }

    @Test("The withheld title matches the nothing-installed-yet title")
    func unavailableTitleMatchesWaiting() {
        // The item is built with this title and falls back to it whenever a
        // hard gate rejects it, so it has to read as a neutral resting state
        // rather than as a claim about the selected VM.
        #expect(
            GuestAgentDiskMenuItem.unavailableTitle
                == GuestAgentDiskMenuItem.model(status: .waiting, isInstallerMounted: false).title)
    }
}

/// Unit tests for the guest-agent disk affordance — the hard gate
/// `MainMenuController.validate` applies before consulting the model above.
@Suite("Guest-agent disk affordance", .admissionGated)
@MainActor
struct GuestAgentDiskEligibilityTests {
    private func eligible(_ instance: VMInstance) -> Bool {
        instance.activity.admits(.affordance(.guestAgentDisk))
    }

    @Test(
        "A live macOS guest can manage the disk",
        arguments: [
            VMLifecyclePhase.running(sessionID: UUID()), .livePaused(sessionID: UUID()),
        ])
    func liveMacOSIsEligible(phase: VMLifecyclePhase) {
        #expect(eligible(VMInstanceFixture.make(guestOS: .macOS, phase: phase)))
    }

    @Test(
        "A live Linux guest cannot — the disk installs a macOS agent",
        arguments: [
            VMLifecyclePhase.running(sessionID: UUID()), .livePaused(sessionID: UUID()),
        ])
    func liveLinuxIsNotEligible(phase: VMLifecyclePhase) {
        #expect(!eligible(VMInstanceFixture.make(guestOS: .linux, phase: phase)))
    }

    @Test("A macOS guest suspended to disk cannot — USB hot-plug needs a live VM")
    func macOSWithoutLiveVMIsNotEligible() {
        #expect(!eligible(VMInstanceFixture.make(guestOS: .macOS, phase: .suspended)))
    }

    @Test(
        "A stopped macOS guest cannot",
        arguments: [
            PhaseFixture.settled(.stopped),
            .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped, boundSession: UUID()),
            .settled(.failed(message: "Boot failed.")),
        ])
    func stoppedMacOSIsNotEligible(phase: PhaseFixture) {
        #expect(!eligible(VMInstanceFixture.make(guestOS: .macOS, phase: phase.phase)))
    }
}
