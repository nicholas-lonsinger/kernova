import AppKit
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// Covers the Guest Agent Status window — what the Virtual Machine menu's
/// Guest Agent Status item opens through `AppWindowRegistry.showGuestAgentStatus(for:)`
/// for the VM the working window shows.
@Suite("Guest agent status window", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct GuestAgentStatusWindowTests {
    private let preferences = makeTestPreferences()

    private struct Fixture {
        let viewModel: VMLibraryViewModel
        let registry: AppWindowRegistry
    }

    private func makeFixture(bundleProducts: AppBundleProducts = .testing) -> Fixture {
        let viewModel = makeLibraryViewModel(preferences: preferences, bundleProducts: bundleProducts)
        return Fixture(viewModel: viewModel, registry: makeWindowRegistry(viewModel))
    }

    /// A Linux VM, selected, whose running session has a channel to the agent hub.
    private func makeLinuxInstance(in viewModel: VMLibraryViewModel) -> VMInstance {
        let instance = makeMenuInstance(in: viewModel, guestOS: .linux, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting().hasAgentTransport = true
        return instance
    }

    private static func peer(_ handle: UInt64, role: PeerRole = .sessionPeer) -> PeerSummary {
        PeerSummary(
            handle: PeerHandle(rawValue: handle), role: role, scope: role == .systemPeer ? .system : .user, os: .linux,
            sessionID: role == .systemPeer ? "" : "2", userName: role == .systemPeer ? "" : "pbear", console: .on,
            versionLabel: "1.0", standing: .current, isResponsive: true)
    }

    private static let currentAgents = AgentHubSnapshot(
        peers: [peer(1), peer(2, role: .systemPeer)], features: FeatureStatus.merge([]))

    private func content(of window: NSWindow) throws -> GuestAgentStatusViewController {
        try #require(window.contentViewController as? GuestAgentStatusViewController)
    }

    @Test("Choosing the item opens the status of the VM the library window has selected")
    func opensForTheSelectedVM() throws {
        let fixture = makeFixture()
        makeMenuInstance(in: fixture.viewModel, name: "Other", phase: .running(sessionID: UUID()))
            .beginSessionContextForTesting()
        let instance = makeMenuInstance(in: fixture.viewModel, name: "Selected", phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting()
        fixture.registry.showLibrary(bringToFront: false)
        let library = try #require(fixture.registry.libraryWindow)
        let target = try #require(fixture.registry.workingInstance(keyWindow: library, mainWindow: library))
        #expect(target === instance)

        fixture.registry.showGuestAgentStatus(for: target)

        let window = try #require(fixture.registry.guestAgentStatusWindow(for: instance.instanceID))
        #expect(window.isVisible)
        #expect(window.title == "Selected — Guest Agent Status")
        let status = try content(of: window)
        #expect(status.presentation == instance.agentPresentation)
        #expect(status.vmName == "Selected")
        #expect(findLabel(withText: "Set up the Kernova guest agent", in: status.view) != nil)
        // The window is that VM's: the menu bar acts on it while it is key.
        #expect(fixture.registry.workingInstance(keyWindow: window, mainWindow: library) === instance)
        #expect(fixture.registry.hasTrackedUserWindow)
    }

    @Test("A healthy agent's status opens while the sidebar badge is hidden")
    func opensWhileTheBadgeIsHidden() throws {
        let fixture = makeFixture()
        let instance = makeLinuxInstance(in: fixture.viewModel)
        instance.publishAgentHubSnapshotForTesting(Self.currentAgents)
        #expect(
            SidebarVMRowCellView.visibleAgentPresentation(for: instance, installPromptDisabled: false) == nil)

        fixture.registry.showGuestAgentStatus(for: instance)

        let window = try #require(fixture.registry.guestAgentStatusWindow(for: instance.instanceID))
        let status = try content(of: window)
        let hub = try #require(instance.agentPresentation?.hub)
        for row in GuestAgentStatusViewController.rows(hub) {
            #expect(findLabel(withText: row.title, in: status.view) != nil, "\(row.title)")
        }
    }

    @Test(
        "No window opens for a VM whose session has no channel to an agent",
        arguments: [
            (VMGuestOS.macOS, PhaseFixture.settled(.stopped), false),
            (.linux, .settled(.stopped), false),
            // A Linux session with no socket device has no agent to show.
            (.linux, .settled(.running(sessionID: UUID())), true),
            (.macOS, .operating(.saving, from: .running(sessionID: UUID())), true),
        ])
    func refusedWithoutAnAgentChannel(guestOS: VMGuestOS, phase: PhaseFixture, hasSessionContext: Bool) {
        let fixture = makeFixture()
        let instance = makeMenuInstance(in: fixture.viewModel, guestOS: guestOS, phase: phase.phase)
        if hasSessionContext { instance.beginSessionContextForTesting() }

        fixture.registry.showGuestAgentStatus(for: instance)

        #expect(fixture.registry.guestAgentStatusWindow(for: instance.instanceID) == nil)
    }

    @Test("Choosing the item again brings the open window forward rather than opening a second")
    func reopenFocusesTheOpenWindow() throws {
        let fixture = makeFixture()
        let instance = makeLinuxInstance(in: fixture.viewModel)
        fixture.registry.showGuestAgentStatus(for: instance)
        let window = try #require(fixture.registry.guestAgentStatusWindow(for: instance.instanceID))
        window.orderOut(nil)

        fixture.registry.showGuestAgentStatus(for: instance)

        #expect(fixture.registry.guestAgentStatusWindow(for: instance.instanceID) === window)
        #expect(window.isVisible)
    }

    @Test("The window follows the agent and refits its content")
    func followsTheAgent() async throws {
        let fixture = makeFixture()
        let instance = makeLinuxInstance(in: fixture.viewModel)
        fixture.registry.showGuestAgentStatus(for: instance)
        let window = try #require(fixture.registry.guestAgentStatusWindow(for: instance.instanceID))
        let status = try content(of: window)
        let waitingHeight = window.contentRect(forFrameRect: window.frame).height
        #expect(waitingHeight == status.view.fittingSize.height)

        instance.publishAgentHubSnapshotForTesting(Self.currentAgents)

        // The window's observation applies on a later main-actor turn, with no
        // observable of its own to await.
        try await waitUntil { status.presentation == instance.agentPresentation }
        let height = window.contentRect(forFrameRect: window.frame).height
        #expect(height == status.view.fittingSize.height)
        #expect(height > waitingHeight)
    }

    @Test("The window closes once the session's agent channel goes")
    func closesWithTheAgentChannel() async throws {
        let fixture = makeFixture()
        let instance = makeMenuInstance(in: fixture.viewModel, guestOS: .linux, phase: .running(sessionID: UUID()))
        let context = instance.beginSessionContextForTesting()
        context.hasAgentTransport = true
        fixture.registry.showGuestAgentStatus(for: instance)
        let window = try #require(fixture.registry.guestAgentStatusWindow(for: instance.instanceID))

        context.hasAgentTransport = false

        try await waitUntil { fixture.registry.guestAgentStatusWindow(for: instance.instanceID) == nil }
        #expect(!window.isVisible)
    }

    @Test("Done closes the window, and the window offers no install-nudge dismissal")
    func doneClosesTheWindow() throws {
        // With no installer to offer, the trailing button is Done.
        let fixture = makeFixture(
            bundleProducts: AppBundleProducts(
                bundleURL: AppBundleProducts.testing.bundleURL, hostVersion: "1.0", buildNumber: "1",
                guestAgents: .none))
        let instance = makeMenuInstance(in: fixture.viewModel, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting()
        fixture.registry.showGuestAgentStatus(for: instance)
        let window = try #require(fixture.registry.guestAgentStatusWindow(for: instance.instanceID))
        let status = try content(of: window)
        #expect(status.actionButtonRole == .done)
        #expect(!status.hasDismissAction)

        try #require(findButton(titled: "Done", in: status.view)).performClick(nil)

        #expect(fixture.registry.guestAgentStatusWindow(for: instance.instanceID) == nil)
        #expect(!window.isVisible)
    }
}
