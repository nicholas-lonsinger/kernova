import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Unit tests for `GuestAgentDiskControl.model(status:isInstallerMounted:)` —
/// the single source of truth every surface's title and
/// `VMLibraryViewModel.toggleGuestAgentDisk` read, so no title can disagree with
/// the action.
@Suite("GuestAgentDiskControl.model", .caseScoped)
struct GuestAgentDiskControlTests {
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
                GuestAgentDiskControl.model(status: status, isInstallerMounted: true)
                    == .init(title: "Eject Guest Agent Media", isEnabled: true, action: .eject))
        }
    }

    @Test(".waiting → Install / enabled / mount(.install)")
    func waiting() {
        #expect(
            GuestAgentDiskControl.model(status: .waiting, isInstallerMounted: false)
                == .init(title: "Install Guest Agent…", isEnabled: true, action: .mount(.install)))
    }

    @Test(".outdated → Update / enabled / mount(.install)")
    func outdated() {
        #expect(
            GuestAgentDiskControl.model(
                status: .outdated(installed: "0.9.0", bundled: "0.9.2"), isInstallerMounted: false)
                == .init(title: "Update Guest Agent…", isEnabled: true, action: .mount(.install)))
    }

    @Test(".expectedMissing → Reinstall / enabled / mount(.install)")
    func expectedMissing() {
        #expect(
            GuestAgentDiskControl.model(
                status: .expectedMissing(expected: "0.9.0"), isInstallerMounted: false)
                == .init(title: "Reinstall Guest Agent…", isEnabled: true, action: .mount(.install)))
    }

    @Test(".current → Manage / enabled / mount(.manage)")
    func current() {
        #expect(
            GuestAgentDiskControl.model(status: .current(version: "0.9.2"), isInstallerMounted: false)
                == .init(title: "Manage Guest Agent…", isEnabled: true, action: .mount(.manage)))
    }

    @Test(".unresponsive → Manage / enabled / mount(.manage) — not reliably transient")
    func unresponsive() {
        #expect(
            GuestAgentDiskControl.model(
                status: .unresponsive(version: "0.9.2"), isInstallerMounted: false)
                == .init(title: "Manage Guest Agent…", isEnabled: true, action: .mount(.manage)))
    }

    @Test(".connecting → Install / disabled / mount(.install) — transient")
    func connecting() {
        #expect(
            GuestAgentDiskControl.model(
                status: .connecting(expected: "0.9.2"), isInstallerMounted: false)
                == .init(title: "Install Guest Agent…", isEnabled: false, action: .mount(.install)))
    }

    @Test("The withheld title matches the nothing-installed-yet title")
    func unavailableTitleMatchesWaiting() {
        // The item is built with this title and falls back to it whenever a
        // hard gate rejects it, so it has to read as a neutral resting state
        // rather than as a claim about the selected VM.
        #expect(
            GuestAgentDiskControl.unavailableTitle
                == GuestAgentDiskControl.model(status: .waiting, isInstallerMounted: false).title)
    }
}
