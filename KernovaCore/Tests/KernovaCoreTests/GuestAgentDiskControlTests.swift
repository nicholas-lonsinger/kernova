import Foundation
import KernovaCommandModel
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

    @Test("The resolver withholds the control from a build with no bundled installer disk")
    func resolverWithholdsWithoutBundledImage() {
        let viewModel = makeLibraryViewModel(
            preferences: makeTestPreferences(),
            bundleProducts: AppBundleProducts(
                bundleURL: AppBundleProducts.testing.bundleURL, hostVersion: "1.0", buildNumber: "1",
                guestAgents: .none))
        let instance = viewModel.library.admitFixture(
            guestOS: .macOS, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting().hasAgentTransport = true
        #expect(viewModel.capabilities.isAvailable(.toggleGuestAgentDisk, on: instance))

        #expect(GuestAgentDiskControl.model(for: instance, in: viewModel.capabilities) == Self.withheld)
    }

    @Test("No session → unavailable title / disabled / mount(.install)")
    func noSession() {
        #expect(
            GuestAgentDiskControl.model(status: nil, isInstallerMounted: false) == Self.withheld)
    }

    @Test(".outdated → Update / enabled / mount(.install)")
    func outdated() {
        #expect(
            GuestAgentDiskControl.model(
                status: .outdated(installed: "0.9.0", bundled: "0.9.2"), isInstallerMounted: false)
                == .init(title: "Update Guest Agent…", isEnabled: true, action: .mount(.install)))
    }

    @Test(".reinstallNeeded → Reinstall / enabled / mount(.install)")
    func reinstallNeeded() {
        #expect(
            GuestAgentDiskControl.model(
                status: .reinstallNeeded(installed: "0.9.0", bundled: "0.9.2", reason: .launchRefused),
                isInstallerMounted: false)
                == .init(title: "Reinstall Guest Agent…", isEnabled: true, action: .mount(.install)))
    }

    @Test(".updating → Manage / disabled: an agent updating itself needs nothing installed")
    func updating() {
        #expect(
            GuestAgentDiskControl.model(
                status: .updating(installed: "0.9.0", bundled: "0.9.2"), isInstallerMounted: false)
                == .init(title: "Manage Guest Agent…", isEnabled: false, action: .mount(.manage)))
    }

    @Test(".current → Manage / enabled / mount(.manage)")
    func current() {
        #expect(
            GuestAgentDiskControl.model(status: .current(version: "0.9.2"), isInstallerMounted: false)
                == .init(title: "Manage Guest Agent…", isEnabled: true, action: .mount(.manage)))
    }

    @Test(".connecting → Install / disabled / mount(.install) — transient")
    func connecting() {
        #expect(
            GuestAgentDiskControl.model(
                status: .connecting(expected: "0.9.2"), isInstallerMounted: false)
                == .init(title: "Install Guest Agent…", isEnabled: false, action: .mount(.install)))
    }

    @Test("On a macOS guest the attached disk carries the step that installs from it; none while detached")
    func macOSGuidance() throws {
        let installer = try #require(BundledGuestAgents.testing.macOSInstallerDiskImageURL)
        let viewModel = makeLibraryViewModel(preferences: makeTestPreferences())
        let detached = viewModel.library.admitFixture(guestOS: .macOS, phase: .running(sessionID: UUID()))
        detached.beginSessionContextForTesting().hasAgentTransport = true
        #expect(GuestAgentDiskControl.model(for: detached, in: viewModel.capabilities).installGuidance == nil)

        let attached = viewModel.library.admitFixture(guestOS: .macOS, phase: .running(sessionID: UUID())) {
            $0.removableMedia = [
                RemovableMediaItem(
                    path: installer.path(percentEncoded: false), readOnly: true, awaitedAgentScopes: [.login])
            ]
        }
        attached.beginSessionContextForTesting().hasAgentTransport = true
        let ejecting = GuestAgentDiskControl.model(for: attached, in: viewModel.capabilities)
        #expect(ejecting.action == .eject)
        #expect(ejecting.installGuidance == .step(GuestAgentDiskControl.macOSInstallStep))
        #expect(GuestAgentDiskControl.macOSInstallStep.contains("install.command"))
    }

    @Test("On a Linux guest the control mounts the agent's disk, and while it is attached carries its command")
    func linuxGuest() throws {
        let agents = BundledGuestAgents.linux(agent: URL(filePath: "/var/empty/kernova-agent"), disk: .testing)
        let viewModel = makeLibraryViewModel(
            preferences: makeTestPreferences(),
            bundleProducts: AppBundleProducts(
                bundleURL: AppBundleProducts.testing.bundleURL, hostVersion: "1.0", buildNumber: "1",
                guestAgents: agents))
        let instance = viewModel.library.admitFixture(guestOS: .linux, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting()
        // A Linux guest's agents are reachable only through the hub's transport.
        #expect(GuestAgentDiskControl.model(for: instance, in: viewModel.capabilities) == Self.withheld)
        instance.attachAgentTransport(AgentHubProbe())
        let detached = GuestAgentDiskControl.model(for: instance, in: viewModel.capabilities)
        #expect(detached.action == .mount(.install))
        #expect(detached.isEnabled)
        #expect(detached.installGuidance == nil)

        // Registered, so the arrival hook reaches the core as a load wires it.
        let attached = viewModel.library.registerFixture(
            name: "Attached", guestOS: .linux, phase: .running(sessionID: UUID())
        ) {
            $0.removableMedia = [
                RemovableMediaItem(
                    path: agents.linuxDisk.url.path(percentEncoded: false), readOnly: true,
                    awaitedAgentScopes: [.login, .system])
            ]
        }
        attached.beginSessionContextForTesting()
        attached.attachAgentTransport(AgentHubProbe())
        let ejecting = GuestAgentDiskControl.model(for: attached, in: viewModel.capabilities)
        #expect(ejecting.action == .eject)
        #expect(ejecting.installGuidance == .command(LinuxAgentDisk.installCommand(for: .both)))

        // The command follows what the disk still waits for: once the session
        // agent connects, the one that installs the system service alone.
        attached.onCurrentAgentsArrived?([.login])
        #expect(
            GuestAgentDiskControl.model(for: attached, in: viewModel.capabilities).installGuidance
                == .command(LinuxAgentDisk.installCommand(for: .systemService)))
    }

    @Test("A Linux disk that waits for no agent offers the session agent's command")
    func linuxManageDiskOffersTheSessionCommand() {
        let agents = BundledGuestAgents.linux(agent: URL(filePath: "/var/empty/kernova-agent"), disk: .testing)
        let viewModel = makeLibraryViewModel(
            preferences: makeTestPreferences(),
            bundleProducts: AppBundleProducts(
                bundleURL: AppBundleProducts.testing.bundleURL, hostVersion: "1.0", buildNumber: "1",
                guestAgents: agents))
        let attached = viewModel.library.admitFixture(guestOS: .linux, phase: .running(sessionID: UUID())) {
            $0.removableMedia = [
                RemovableMediaItem(path: agents.linuxDisk.url.path(percentEncoded: false), readOnly: true)
            ]
        }
        attached.beginSessionContextForTesting()
        attached.attachAgentTransport(AgentHubProbe())
        #expect(
            GuestAgentDiskControl.model(for: attached, in: viewModel.capabilities).installGuidance
                == .command(LinuxAgentDisk.installCommand(for: .sessionAgent)))
    }
}
