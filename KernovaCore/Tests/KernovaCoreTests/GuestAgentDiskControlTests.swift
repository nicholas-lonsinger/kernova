import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Unit tests for `GuestAgentDiskControl` — the resolver every surface's title
/// and `VMLibraryViewModel.toggleGuestAgentDisk` read, so no title can disagree
/// with the action, and the status mapping under it.
@Suite("GuestAgentDiskControl.model", .caseScoped)
@MainActor
struct GuestAgentDiskControlTests {
    private static let withheld = GuestAgentDiskControl.Model(
        title: GuestAgentDiskControl.unavailableTitle, isEnabled: false, action: .mount(.install))

    /// The affordance takes a settled live session, so an operation holding
    /// one withholds the control whatever the status would offer.
    @Test("The resolver withholds the control during an operation that holds a session")
    func resolverWithholdsDuringOperation() {
        let viewModel = makeLibraryViewModel(preferences: makeTestPreferences())
        let instance = viewModel.library.admitFixture(
            guestOS: .macOS, phase: .operating(.saving, from: .running(sessionID: UUID())))
        instance.beginSessionContextForTesting()
        #expect(instance.agentStatus == .waiting)

        #expect(GuestAgentDiskControl.model(for: instance, in: viewModel.capabilities) == Self.withheld)
    }

    @Test("The resolver passes the status mapping through while the control is available")
    func resolverPassesStatusMappingThrough() {
        let viewModel = makeLibraryViewModel(preferences: makeTestPreferences())
        let instance = viewModel.library.admitFixture(
            guestOS: .macOS, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting()

        #expect(
            GuestAgentDiskControl.model(for: instance, in: viewModel.capabilities)
                == GuestAgentDiskControl.model(status: .waiting, isInstallerMounted: false))
    }

    @Test("The resolver withholds the control from a build with no bundled installer disk")
    func resolverWithholdsWithoutBundledImage() {
        let viewModel = makeLibraryViewModel(
            preferences: makeTestPreferences(),
            bundleProducts: AppBundleProducts(
                bundleURL: AppBundleProducts.testing.bundleURL, hostVersion: "1.0", buildNumber: "1",
                guestAgent: BundledGuestAgent(version: "2.0", installerDiskImageURL: nil)))
        let instance = viewModel.library.admitFixture(
            guestOS: .macOS, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting()
        #expect(viewModel.capabilities.isAvailable(.toggleGuestAgentDisk, on: instance))

        #expect(GuestAgentDiskControl.model(for: instance, in: viewModel.capabilities) == Self.withheld)
    }

    @Test("Attached installer → eject mode, regardless of agent status or its absence")
    func attachedEjectsRegardlessOfStatus() {
        let statuses: [AgentStatus?] = [
            nil,
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

    @Test("No session → unavailable title / disabled / mount(.install)")
    func noSession() {
        #expect(
            GuestAgentDiskControl.model(status: nil, isInstallerMounted: false) == Self.withheld)
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
