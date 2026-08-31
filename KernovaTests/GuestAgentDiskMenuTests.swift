import Foundation
import Testing

@testable import Kernova

/// Unit tests for `GuestAgentDiskMenuItem.model(status:isInstallerMounted:)` —
/// the single source of truth shared by `AppDelegate.validateMenuItem` and
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

/// Unit tests for `VMInstance.canManageGuestAgentDisk` — the hard gate
/// `AppDelegate.validateMenuItem` applies before consulting the model above.
@Suite("VMInstance.canManageGuestAgentDisk", .admissionGated)
@MainActor
struct GuestAgentDiskEligibilityTests {
    private func makeInstance(guestOS: VMGuestOS, phase: VMLifecyclePhase) -> VMInstance {
        let config = VMConfiguration(
            name: "Test VM", guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL, phase: phase)
    }

    @Test(
        "A live macOS guest can manage the disk",
        arguments: [
            VMLifecyclePhase.running(sessionID: UUID()), .livePaused(sessionID: UUID()),
        ])
    func liveMacOSIsEligible(phase: VMLifecyclePhase) {
        #expect(makeInstance(guestOS: .macOS, phase: phase).canManageGuestAgentDisk)
    }

    @Test(
        "A live Linux guest cannot — the disk installs a macOS agent",
        arguments: [
            VMLifecyclePhase.running(sessionID: UUID()), .livePaused(sessionID: UUID()),
        ])
    func liveLinuxIsNotEligible(phase: VMLifecyclePhase) {
        #expect(!makeInstance(guestOS: .linux, phase: phase).canManageGuestAgentDisk)
    }

    @Test("A macOS guest suspended to disk cannot — USB hot-plug needs a live VM")
    func macOSWithoutLiveVMIsNotEligible() {
        #expect(!makeInstance(guestOS: .macOS, phase: .suspended).canManageGuestAgentDisk)
    }

    @Test(
        "A stopped macOS guest cannot",
        arguments: [
            VMLifecyclePhase.stopped, .starting(sessionID: UUID()),
            .failed(message: "Boot failed."),
        ])
    func stoppedMacOSIsNotEligible(phase: VMLifecyclePhase) {
        #expect(!makeInstance(guestOS: .macOS, phase: phase).canManageGuestAgentDisk)
    }
}
