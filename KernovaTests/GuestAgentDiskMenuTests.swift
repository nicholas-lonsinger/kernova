import Testing

@testable import Kernova

/// Unit tests for `GuestAgentDiskMenuItem.model(status:isInstallerMounted:)` —
/// the single source of truth shared by `AppDelegate.validateMenuItem` and
/// `toggleGuestAgentDisk`, so the menu title can never disagree with the action.
@Suite("GuestAgentDiskMenuItem.model")
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
}
