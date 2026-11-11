import AppKit
import KernovaAgentCore
import KernovaAgentHost
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI
@testable import KernovaVirtualization

/// Behavioral tests for the pure-AppKit sidebar.
///
/// Covers the non-trivial logic that survives the SwiftUI→AppKit port: the
/// status-dot color mapping, the guest-agent indicator gating, inline rename,
/// and the status-dependent context menu. Pure
/// layout/rendering is left to manual verification, per the project's testing
/// guidance.
@Suite("Sidebar Tests", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct SidebarViewControllerTests {
    /// Shared by the view model (selection/order) and the sidebar's own use of
    /// `AppPreferences` (expanded sections + the advanced-options toggle).
    ///
    /// Fresh per test (the struct is re-instantiated), so each starts clean.
    private let preferences: AppPreferences

    init() {
        self.preferences = makeTestPreferences()
    }

    private func makeViewModel(
        storageService: MockVMStorageService = MockVMStorageService(), bundleProducts: AppBundleProducts = .testing
    ) -> VMLibraryViewModel {
        VMLibraryViewModel(
            storageService: storageService,
            diskImageService: MockDiskImageService(),
            machineFiles: VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles()),
            virtualizationHost: VirtualizationHost(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            localImageInspector: LocalRestoreImageInspector(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            bridgedInterfaces: HostBridgedInterfaceProvider(),
            fileSystem: MockFileSystem(),
            downloadsDirectory: makeTestDownloadsDirectory(),
            preferences: preferences,
            vmnetNetworks: VmnetNetworkService.scripted(),
            arpTable: ScriptedARPTable(),
            entitlements: .entitled,
            hostNotifications: .isolated(),
            hostPasteboard: FakePasteboard(),
            bundleProducts: bundleProducts
        )
    }

    /// The sidebar badge gate with the app-wide install prompt left on, which is
    /// every case but the ones exercising that preference.
    private func visibleAgentStatus(for instance: VMInstance) -> AgentStatus? {
        SidebarVMRowCellView.visibleAgentPresentation(for: instance, installPromptDisabled: false)?.status
    }

    private func titles(of menu: NSMenu) -> [String] {
        menu.items.map(\.title)
    }

    /// `name`'s laid-out width in `font`, through a field configured like the
    /// row's name label.
    ///
    /// An oracle independent of the cell's own measuring path, so a test using it
    /// checks the fonts rather than re-running the code under test.
    private func measuredWidth(of name: String, at font: NSFont) -> CGFloat {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = false
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.font = font
        field.stringValue = name
        return ceil(field.fittingSize.width)
    }

    private func menuItem(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    // MARK: - Agent indicator gating

    private static func peer(
        _ handle: UInt64, role: PeerRole = .sessionPeer, standing: PeerSummary.Standing = .current
    ) -> PeerSummary {
        PeerSummary(
            handle: PeerHandle(rawValue: handle), role: role, scope: role == .systemPeer ? .system : .user, os: .linux,
            sessionID: role == .systemPeer ? "" : "2", userName: role == .systemPeer ? "" : "pbear", console: .on,
            versionLabel: "1.0", standing: standing, isResponsive: true)
    }

    @Test("A Linux guest's indicator follows the status rule a macOS guest's does")
    func agentShownForLinuxWithAnAgent() {
        let instance = VMInstanceFixture.make(guestOS: .linux, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting().hasAgentTransport = true
        // None connected: waiting, shown.
        #expect(instance.agentPresentation?.status == .waiting)
        #expect(visibleAgentStatus(for: instance) == .waiting)

        // Every agent current: hidden.
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(
                peers: [Self.peer(1), Self.peer(2, role: .systemPeer)], features: FeatureStatus.merge([])))
        #expect(visibleAgentStatus(for: instance) == nil)

        // One outdated: shown, as outdated.
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(
                peers: [
                    Self.peer(1),
                    Self.peer(
                        3, role: .systemPeer, standing: .outdated(offeredVersionLabel: "2.0", update: .unavailable)),
                ],
                features: FeatureStatus.merge([])))
        #expect(visibleAgentStatus(for: instance) == .outdated(installed: "1.0", bundled: "2.0"))

        // Waiting with the nudge dismissed: hidden.
        let dismissed = VMInstanceFixture.make(
            guestOS: .linux, phase: .running(sessionID: UUID()),
            hostState: VMHostState(agentInstallNudgeDismissed: true))
        dismissed.beginSessionContextForTesting().hasAgentTransport = true
        #expect(dismissed.agentPresentation?.status == .waiting)
        #expect(visibleAgentStatus(for: dismissed) == nil)
    }

    @Test("Agent indicator suppressed for a stopped macOS VM")
    func agentSuppressedWhenStopped() {
        // Neither a VM that has never had an agent nor one that has: with no
        // session, `agentStatus` makes no statement to render.
        let fresh = VMInstanceFixture.make(guestOS: .macOS, phase: .stopped)
        #expect(visibleAgentStatus(for: fresh) == nil)

        let seen = VMInstanceFixture.make(guestOS: .macOS, phase: .stopped) {
            $0.lastSeenAgentVersion = "1.2.3"
        }
        #expect(visibleAgentStatus(for: seen) == nil)
    }

    // MARK: - Row busy state

    /// The cell holds its instance weakly, so the caller keeps `instance` alive:
    /// binding a temporary would leave the row on a deallocated VM, and its
    /// observation loop registering nothing.
    private func makeRow(
        instance: VMInstance, isBusy: Bool,
        diskControl: @escaping () -> GuestAgentDiskControl.Model? = { nil }
    ) -> SidebarVMRowCellView {
        let cell = SidebarVMRowCellView()
        cell.configure(
            instance: instance,
            isRenaming: false,
            installPromptDisabled: { false },
            agentDiskControl: diskControl,
            agentNudgeDismissible: { false },
            isBusy: { isBusy },
            detail: { nil },
            tags: { [] },
            onCommitRename: { _ in },
            onCancelRename: {},
            onAgentDiskControl: {},
            onDismissAgentNudge: {})
        return cell
    }

    /// The row is the only surface that can show a settling pause or resume, so
    /// its spinner follows the view model's busy read rather than the status —
    /// which stays `.running` (pause) or `.paused` (resume) throughout.
    @Test("The row swaps its OS icon for the spinner while busy")
    func rowSpinsWhileBusy() {
        let busyInstance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        let busy = makeRow(instance: busyInstance, isBusy: true)
        #expect(firstSubview(NSProgressIndicator.self, in: busy)?.isHidden == false)
        #expect(firstSubview(NSImageView.self, in: busy)?.isHidden == true)

        let idleInstance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        let idle = makeRow(instance: idleInstance, isBusy: false)
        #expect(firstSubview(NSProgressIndicator.self, in: idle)?.isHidden == true)
        #expect(firstSubview(NSImageView.self, in: idle)?.isHidden == false)
    }

    /// The badge's popover offers the guest-agent disk control, whose mode
    /// turns on the installer's attached state as well as the agent status — so
    /// attaching the disk with the status unchanged must still reach the badge.
    @Test("The agent badge follows the installer's attached state")
    func agentBadgeFollowsInstallerAttachment() async throws {
        _ = try #require(BundledGuestAgents.testing.macOSInstallerDiskImageURL)
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(
            guestOS: .macOS, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting().hasAgentTransport = true
        let cell = makeRow(instance: instance, isBusy: false) {
            GuestAgentDiskControl.model(for: instance, in: viewModel.capabilities)
        }
        let badge = try #require(firstSubview(SidebarAgentStatusButtonView.self, in: cell))
        #expect(!badge.isHidden)
        #expect(badge.status == .waiting)
        #expect(badge.diskControl?.action != .eject)

        await viewModel.toggleGuestAgentDisk(on: instance)
        #expect(instance.hasGuestAgentInstallerMounted)
        #expect(instance.agentPresentation?.status == .waiting)

        // The cell's observation applies on a later main-actor turn, with no
        // observable of its own to await.
        try await waitUntil { badge.diskControl?.action == .eject }
    }

    /// An agent that can't take the bundled build in place — it refused it as
    /// one it can't launch, or this build bundles one signed with no team — is
    /// the existing badge in its reinstall state: the badge, its popover's text
    /// and its action all say to reinstall from the installer disk.
    @Test(
        "A macOS guest's badge for an agent that can't update in place offers the reinstall and says why",
        arguments: [
            (
                PeerSummary.InBandUpdate.launchRefused, AgentStatus.ReinstallReason.launchRefused,
                "This agent has a different signature from the one Kernova bundles, so it can\u{2019}t update "
                    + "in place. Reinstall it from the installer disk."
            ),
            (
                .notTeamSigned, .notTeamSigned,
                "This build of Kernova bundles a guest agent signed without a team, so agents can\u{2019}t update "
                    + "in place. Reinstall it from the installer disk. A build signed with a development team "
                    + "updates agents in place."
            ),
        ])
    func badgeOffersReinstallForAnAgentThatCantUpdateInPlace(
        update: PeerSummary.InBandUpdate, reason: AgentStatus.ReinstallReason, explanation: String
    ) throws {
        _ = try #require(BundledGuestAgents.testing.macOSInstallerDiskImageURL)
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(guestOS: .macOS, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting().hasAgentTransport = true
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(
                peers: [
                    Self.peer(
                        3, role: .systemPeer, standing: .outdated(offeredVersionLabel: "2.0", update: update))
                ],
                features: FeatureStatus.merge([])))
        let cell = makeRow(instance: instance, isBusy: false) {
            GuestAgentDiskControl.model(for: instance, in: viewModel.capabilities)
        }

        let badge = try #require(firstSubview(SidebarAgentStatusButtonView.self, in: cell))
        #expect(!badge.isHidden)
        #expect(badge.status == .reinstallNeeded(installed: "1.0", bundled: "2.0", reason: reason))
        #expect(SidebarAgentStatusButtonView.symbolName(for: badge.status) == "exclamationmark.triangle.fill")
        #expect(badge.toolTip == "Guest agent can't update in place (1.0 → 2.0)")
        let control = try #require(badge.diskControl)
        #expect(control == .init(title: "Reinstall Guest Agent…", isEnabled: true, action: .mount(.install)))

        let popover = GuestAgentStatusViewController()
        popover.update(
            presentation: badge.presentation, diskControl: control, hasDismissAction: badge.hasDismissAction)
        popover.loadViewIfNeeded()
        let texts = visibleTexts(in: popover.view)
        #expect(texts.first == "Guest agent can\u{2019}t update in place")
        #expect(texts.dropFirst().first == explanation)
        #expect(texts.contains("Can\u{2019}t update in place"))
        #expect(
            firstSubview(NSButton.self, in: popover.view) { $0.title == "Reinstall Guest Agent…" }?.isHidden == false)

        // Any other status hides the explanation.
        popover.update(
            presentation: GuestAgentPresentation(hub: .empty), diskControl: control, hasDismissAction: false)
        #expect(!visibleTexts(in: popover.view).contains(explanation))
    }

    /// A session agent that left this session, its grace passed, is the gray
    /// badge offering an install, which a dismissed install nudge doesn't hide.
    @Test("A macOS guest's badge for a session agent that disconnected offers an install and says what's known")
    func badgeOffersInstallForADisconnectedAgent() throws {
        _ = try #require(BundledGuestAgents.testing.macOSInstallerDiskImageURL)
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(guestOS: .macOS, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting().hasAgentTransport = true
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(peers: [Self.peer(1)], features: FeatureStatus.merge([])))
        // Its away line already expired: the hub lists nothing.
        instance.publishAgentHubSnapshotForTesting(.empty)
        viewModel.library.editHostState(of: instance) { $0.agentInstallNudgeDismissed = true }
        let cell = makeRow(instance: instance, isBusy: false) {
            GuestAgentDiskControl.model(for: instance, in: viewModel.capabilities)
        }

        let badge = try #require(firstSubview(SidebarAgentStatusButtonView.self, in: cell))
        #expect(!badge.isHidden)
        #expect(badge.status == .disconnected(last: "1.0"))
        #expect(SidebarAgentStatusButtonView.symbolName(for: badge.status) == "exclamationmark.circle.fill")
        #expect(badge.toolTip == "Guest agent disconnected (was 1.0)")
        let control = try #require(badge.diskControl)
        #expect(control == .init(title: "Install Guest Agent…", isEnabled: true, action: .mount(.install)))

        let popover = GuestAgentStatusViewController()
        popover.update(
            presentation: badge.presentation, diskControl: control, hasDismissAction: badge.hasDismissAction)
        popover.loadViewIfNeeded()
        let texts = visibleTexts(in: popover.view)
        #expect(texts.first == "Guest agent disconnected")
        #expect(
            texts.dropFirst().first
                == "The session agent disconnected and hasn\u{2019}t come back. An installed session agent "
                + "connects again when its user logs in to the guest.")
        #expect(texts.contains("Disconnected"))
        #expect(
            firstSubview(NSButton.self, in: popover.view) { $0.title == "Install Guest Agent…" }?.isHidden == false)
    }

    /// The text of every label on screen, in document order: none under a hidden view.
    private func visibleTexts(in view: NSView) -> [String] {
        guard !view.isHidden else { return [] }
        var texts: [String] = []
        if let field = view as? NSTextField, !field.isEditable { texts.append(field.stringValue) }
        for subview in view.subviews { texts += visibleTexts(in: subview) }
        return texts
    }

    /// The preference lives in Settings, so it changes while every row is up.
    @Test("The agent badge follows the app-wide install-prompt preference")
    func agentBadgeFollowsAppWidePreference() async throws {
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(
            guestOS: .macOS, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting().hasAgentTransport = true
        let cell = SidebarVMRowCellView()
        cell.configure(
            instance: instance,
            isRenaming: false,
            installPromptDisabled: { viewModel.agentInstallPromptDisabled },
            agentDiskControl: { GuestAgentDiskControl.model(for: instance, in: viewModel.capabilities) },
            agentNudgeDismissible: { false },
            isBusy: { false },
            detail: { nil },
            tags: { [] },
            onCommitRename: { _ in },
            onCancelRename: {},
            onAgentDiskControl: {},
            onDismissAgentNudge: {})
        let badge = try #require(firstSubview(SidebarAgentStatusButtonView.self, in: cell))
        #expect(!badge.isHidden)

        viewModel.agentInstallPromptDisabled = true

        // The cell's observation applies on a later main-actor turn, with no
        // observable of its own to await.
        try await waitUntil { badge.isHidden }
    }

    /// The badge now shows through an operation that holds a session, which
    /// takes neither the disk control nor the dismissal's write — so both have
    /// to follow the phase, not only the agent status.
    @Test("The agent badge withholds its disk control and dismissal during an operation")
    func agentBadgeWithholdsControlsDuringOperation() async throws {
        _ = try #require(BundledGuestAgents.testing.macOSInstallerDiskImageURL)
        let viewModel = makeViewModel()
        let sessionID = UUID()
        let instance = viewModel.library.admitFixture(guestOS: .macOS, phase: .running(sessionID: sessionID))
        instance.beginSessionContextForTesting().hasAgentTransport = true
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        controller.viewDidAppear()
        let outline = try #require(firstSubview(NSOutlineView.self, in: controller.view))
        let cell = try #require(
            outline.view(atColumn: 0, row: 1, makeIfNecessary: true) as? SidebarVMRowCellView)
        let badge = try #require(firstSubview(SidebarAgentStatusButtonView.self, in: cell))
        #expect(!badge.isHidden)
        #expect(badge.diskControl?.isEnabled == true)
        #expect(badge.hasDismissAction)

        instance.activity.placeForTesting(.operating(.saving, from: .running(sessionID: sessionID)))

        // The cell's observation applies on a later main-actor turn, with no
        // observable of its own to await.
        try await waitUntil { badge.diskControl?.isEnabled == false && !badge.hasDismissAction }
        #expect(!badge.isHidden)
        #expect(badge.status == .waiting)
    }

    // MARK: - Inline rename

    /// The row's name label, which is also the box a rename opens.
    private func nameLabel(in cell: SidebarVMRowCellView) throws -> InlineEditableLabel {
        try #require(firstSubview(InlineEditableLabel.self, in: cell))
    }

    private func makeRenamingRow(
        instance: VMInstance, onCommitRename: @escaping (String) -> Void = { _ in }
    ) -> SidebarVMRowCellView {
        let cell = SidebarVMRowCellView()
        cell.configure(
            instance: instance,
            isRenaming: true,
            installPromptDisabled: { false },
            agentDiskControl: { nil },
            agentNudgeDismissible: { false },
            isBusy: { false },
            detail: { nil },
            tags: { [] },
            onCommitRename: onCommitRename,
            onCancelRename: {},
            onAgentDiskControl: {},
            onDismissAgentNudge: {})
        return cell
    }

    @Test("The rename box fits the name, and the slow-click region still spans the name line")
    func renameBoxHugsTheNameInsideAFullWidthClickRegion() throws {
        let instance = VMInstanceFixture.make()
        let cell = makeRenamingRow(instance: instance)
        let window = makeTestWindow(styleMask: [.titled])
        window.setContentSize(NSSize(width: 320, height: 40))
        window.contentView = cell
        cell.layoutSubtreeIfNeeded()
        let label = try nameLabel(in: cell)
        let nameWidth = ceil(
            NSAttributedString(string: instance.name, attributes: [.font: label.font!]).size().width)

        #expect(label.frame.width >= nameWidth)
        // The box hugs the name rather than spanning the row.
        #expect(label.frame.width < cell.bounds.width / 2)

        cell.endRename()
        cell.layoutSubtreeIfNeeded()
        // Past the end of the name, still on its line.
        let pastName = label.convert(
            NSPoint(x: label.bounds.maxX + 20, y: label.bounds.midY), to: cell)
        #expect(cell.isPointOverName(pastName))
    }

    /// The label hands the focus back to the outline view when Return ends
    /// its edit, as a table's own cell edit does.
    @Test("Return on a row's rename commits it and hands the focus back to the sidebar")
    func returnHandsFocusBackToTheSidebar() throws {
        let viewModel = makeViewModel()
        let alpha = viewModel.library.admitFixture(name: "Alpha")
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        viewModel.renameVMInSidebar(alpha)
        controller.viewDidAppear()
        let node = try #require(controller.tree.row(for: .library(alpha.id)))
        let cell = try #require(
            outline.view(atColumn: 0, row: outline.row(forItem: node), makeIfNecessary: false)
                as? SidebarVMRowCellView)
        let editor = try #require(try nameLabel(in: cell).currentEditor() as? NSTextView)

        typeAndReturn("Renamed", in: editor)

        #expect(alpha.name == "Renamed")
        #expect(!cell.isRenaming)
        #expect(outline.window?.firstResponder === outline)
    }

    /// A recycled row carries typed text belonging to the VM it used to show,
    /// so the reuse teardown must drop it rather than commit it.
    @Test("Recycling a row mid-rename commits nothing")
    func recyclingARenamingRowCommitsNothing() throws {
        let instance = VMInstanceFixture.make()
        var commits = 0
        let cell = makeRenamingRow(instance: instance) { _ in commits += 1 }
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = cell
        let label = try nameLabel(in: cell)
        label.currentEditor()?.string = "Half-typed"
        label.stringValue = "Half-typed"

        cell.prepareForReuse()

        #expect(commits == 0)
        #expect(!cell.isRenaming)
        #expect(!label.isEditable)
    }

    /// The sidebar applies a library change as inserts and removes, so a row
    /// the change leaves alone keeps its view — and the edit open in it.
    @Test("A library change elsewhere leaves an open rename's row and edit in place")
    func renameSurvivesUnrelatedLibraryChange() async throws {
        let viewModel = makeViewModel()
        let alpha = viewModel.library.admitFixture(name: "Alpha")
        let controller = SidebarViewController(viewModel: viewModel)
        let window = showTestWindow(
            styleMask: [.titled], contentSize: NSSize(width: 300, height: 400))
        window.contentView = controller.view
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidAppear()
        let outline = try #require(firstSubview(NSOutlineView.self, in: controller.view))
        func alphaCell() -> SidebarVMRowCellView? {
            outline.view(atColumn: 0, row: 1, makeIfNecessary: false) as? SidebarVMRowCellView
        }

        viewModel.renameVMInSidebar(alpha)
        // The rename reaches the row through the sidebar's own observation
        // loop, which offers no test-facing signal to await.
        try await waitUntil { alphaCell()?.isRenaming == true }
        let editing = try #require(alphaCell())

        viewModel.library.admitFixture(name: "Beta")
        try await waitUntil { outline.numberOfRows == 3 }

        #expect(alphaCell() === editing)
        #expect(editing.isRenaming)
        #expect(viewModel.activeRename == .sidebar(.entry(alpha.id)))
    }

    /// A move takes the row's view down, which would drop the typed name with
    /// it; the update commits it first.
    @Test("A rename whose row an update moves commits its text first")
    func renameCommitsWhenItsRowMoves() async throws {
        let storage = MockVMStorageService()
        let viewModel = makeViewModel(storageService: storage)
        let alpha = viewModel.library.admitFixture(name: "Alpha", files: storage.files)
        viewModel.library.admitFixture(name: "Beta", files: storage.files)
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        func alphaCell() -> SidebarVMRowCellView? {
            outline.view(atColumn: 0, row: 1, makeIfNecessary: false) as? SidebarVMRowCellView
        }
        viewModel.renameVMInSidebar(alpha)
        // The rename reaches the row through the sidebar's own observation
        // loop, which offers no test-facing signal to await.
        try await waitUntil { alphaCell()?.isRenaming == true }
        let label = try nameLabel(in: try #require(alphaCell()))
        let editor = try #require(label.currentEditor())
        editor.string = "Renamed"

        viewModel.moveEntries(fromOffsets: [0], toOffset: 2)

        try await waitForChange { viewModel.activeRename == nil }
        #expect(alpha.name == "Renamed")
        try await waitUntil { rowNames(in: outline) == ["Beta", "Renamed"] }
        let moved = try #require(
            outline.view(atColumn: 0, row: 2, makeIfNecessary: true) as? SidebarVMRowCellView)
        #expect(!moved.isRenaming)
    }

    /// VM ▸ Rename names the VM of the key window, which can be one the
    /// sidebar's filter hides.
    @Test("A sidebar rename of a VM the filter hides reveals its row and opens there")
    func renameRevealsAHiddenRow() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Linux", guestOS: .linux)
        let mac = viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        #expect(rowNames(in: outline) == ["Linux"])

        viewModel.renameVMInSidebar(mac)
        controller.viewDidAppear()

        #expect(viewModel.sidebarOptions.filter == VMLibraryFilter())
        #expect(viewModel.selection == .library(mac.id))
        let node = try #require(controller.tree.row(for: .library(mac.id)))
        let row = outline.row(forItem: node)
        let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarVMRowCellView)
        #expect(cell.isRenaming)
        #expect(viewModel.activeRename == .sidebar(.entry(mac.id)))
    }

    @Test("A sidebar rename whose row a filter hides before it opens ends, and opens nothing when the row returns")
    func renameWithNoRowLapses() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Linux", guestOS: .linux)
        let mac = viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)

        viewModel.renameVMInSidebar(mac)
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])
        #expect(viewModel.activeRename == nil)

        viewModel.sidebarOptions.filter = VMLibraryFilter()
        controller.viewDidAppear()
        #expect(viewModel.activeRename == nil)
        #expect(!isRenamingAnyRow(in: outline))
    }

    /// A folder's header and a VM's row hold the one rename between them: the
    /// one opened last takes over, and the text typed into the other lands.
    @Test("Opening a header's rename commits a row's open one, and the reverse")
    func headerAndRowRenamesTakeOverFromEachOther() throws {
        let storage = MockVMStorageService()
        let viewModel = makeViewModel(storageService: storage)
        let alpha = viewModel.library.admitFixture(name: "Alpha", files: storage.files)
        let beta = viewModel.library.admitFixture(name: "Beta", files: storage.files)
        let folder = try viewModel.library.createFolder(named: "Clients")
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        func cell(of instance: VMInstance) throws -> SidebarVMRowCellView {
            let node = try #require(controller.tree.row(for: .library(instance.id)))
            return try #require(
                outline.view(atColumn: 0, row: outline.row(forItem: node), makeIfNecessary: false)
                    as? SidebarVMRowCellView)
        }
        viewModel.renameVMInSidebar(alpha)
        controller.viewDidAppear()
        try #require(try nameLabel(in: try cell(of: alpha)).currentEditor()).string = "Alpha 2"

        let menu = try #require(controller.viewMenu(for: .folder(folder.id)))
        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == "Rename Folder" }))

        #expect(alpha.name == "Alpha 2")
        #expect(try !cell(of: alpha).isRenaming)
        #expect(viewModel.activeRename == .sidebar(.group(.folder, folder.id)))
        let header = try #require(sectionHeader(.folder(folder.id), in: outline))
        try #require(renameEditor(of: header)).string = "Clients 2"

        viewModel.renameVMInSidebar(beta)
        controller.viewDidAppear()

        #expect(viewModel.library.folders?.map(\.name) == ["Clients 2"])
        #expect(!header.isRenaming)
        #expect(try cell(of: beta).isRenaming)
        #expect(viewModel.activeRename == .sidebar(.entry(beta.id)))
    }

    /// The edit box takes the focus wherever it opens, so the selection reads
    /// as unfocused for a header's rename as for the selected row's own.
    @Test("The selected row reads as unfocused while a header's rename is open, and settles after")
    func selectionReadsUnfocusedDuringAHeaderRename() async throws {
        let viewModel = makeViewModel()
        let alpha = viewModel.library.admitFixture(name: "Alpha")
        let folder = try viewModel.library.createFolder(named: "Clients")
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let node = try #require(controller.tree.row(for: .library(alpha.id)))
        outline.selectRowIndexes([outline.row(forItem: node)], byExtendingSelection: false)
        let rowView = try #require(
            outline.rowView(atRow: outline.selectedRow, makeIfNecessary: false) as? SidebarTableRowView)

        let menu = try #require(controller.viewMenu(for: .folder(folder.id)))
        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == "Rename Folder" }))
        let header = try #require(sectionHeader(.folder(folder.id), in: outline))
        try #require(header.isRenaming)
        #expect(rowView.rendersUnemphasized)

        typeAndReturn("Clients 2", in: try #require(renameEditor(of: header)))
        // The emphasis settles on a later main-actor turn, once the field
        // editor has given up the focus, with no observable to await.
        try await waitUntil { !rowView.rendersUnemphasized }
    }

    /// Another copy of Kernova, or a script, can rename the folder while its
    /// header is being edited; the sidebar re-renders headers in place, so
    /// the box and what was typed in it stay.
    @Test("A header's open rename stays, with its text, through library changes, its own folder's rename included")
    func headerRenameSurvivesLibraryChanges() throws {
        let viewModel = makeViewModel()
        let alpha = viewModel.library.admitFixture(name: "Alpha")
        let folder = try viewModel.library.createFolder(named: "Clients")
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        controller.renameGroup(.folder, folder.id)
        let header = try #require(sectionHeader(.folder(folder.id), in: outline))
        try #require(renameEditor(of: header)).string = "Typed"

        try viewModel.library.add([alpha.id], toFolder: folder.id)
        try viewModel.library.renameFolder(folder.id, to: "Elsewhere")
        viewModel.library.admitFixture(name: "Beta")
        controller.viewDidAppear()

        #expect(controller.tree.sections.first { $0.id == .folder(folder.id) }?.title == "Elsewhere")
        #expect(sectionHeader(.folder(folder.id), in: outline) === header)
        #expect(renameEditor(of: header)?.string == "Typed")
        #expect(viewModel.activeRename == .sidebar(.group(.folder, folder.id)))
    }

    private func isRenamingAnyRow(in outline: NSOutlineView) -> Bool {
        (0..<outline.numberOfRows).contains {
            (outline.view(atColumn: 0, row: $0, makeIfNecessary: false) as? SidebarVMRowCellView)?.isRenaming == true
        }
    }

    // MARK: - Outline updates

    /// Hosts the controller's view in an ordered-in window, so the outline view
    /// realizes cells.
    private func shownOutline(of controller: SidebarViewController) throws -> NSOutlineView {
        let window = showTestWindow(
            styleMask: [.titled], contentSize: NSSize(width: 300, height: 600))
        window.contentView = controller.view
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidAppear()
        return try #require(firstSubview(NSOutlineView.self, in: controller.view))
    }

    /// The names of the leaf rows below the section header, as the rows hold them.
    private func rowNames(in outline: NSOutlineView) -> [String] {
        (1..<outline.numberOfRows).map {
            (outline.item(atRow: $0) as? SidebarRow)?.entry.name ?? "?"
        }
    }

    /// The names the leaf rows' cells display.
    private func cellNames(in outline: NSOutlineView) -> [String] {
        (1..<outline.numberOfRows).map { row in
            let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
            return cell?.textField?.stringValue ?? "?"
        }
    }

    /// Removals index the previous children and insertions the current ones,
    /// so one update that mixes them only lands when applied in that order.
    @Test("One update that removes, moves and inserts rows lands every row and keeps the selection")
    func mixedUpdateLandsEveryRow() async throws {
        let viewModel = makeViewModel()
        let library = viewModel.library
        library.admitFixture(name: "A")
        let b = library.admitFixture(name: "B")
        let c = library.admitFixture(name: "C")
        library.admitFixture(name: "D")
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        #expect(rowNames(in: outline) == ["A", "B", "C", "D"])
        viewModel.selectRevealing(c.id)
        // The outline view offers no observable to await its selection by.
        try await waitUntil { outline.selectedRow == 3 }

        // All in one main-actor turn, so the sidebar applies them as one update.
        library.evict(b)  // A C D
        library.moveEntries(fromOffsets: [2], toOffset: 0)  // D A C
        library.admitFixture(name: "E")  // D A C E
        library.moveEntries(fromOffsets: [1], toOffset: 4)  // D C E A

        try await waitUntil { rowNames(in: outline) == ["D", "C", "E", "A"] }
        #expect(cellNames(in: outline) == ["D", "C", "E", "A"])
        #expect(outline.selectedRow == 2)
        #expect(viewModel.selectedID == c.id)
    }

    /// Below the last row AppKit proposes the root with
    /// `NSOutlineViewDropOnItemIndex`.
    @Test("Dropping a row in the empty space below the list moves it to the end")
    func dropBelowTheListAppends() throws {
        let viewModel = makeViewModel()
        let library = viewModel.library
        library.admitFixture(name: "A")
        let b = library.admitFixture(name: "B")
        library.admitFixture(name: "C")
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sidebar-drop-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(
            try JSONEncoder().encode(SidebarRowKey.library(b.id)),
            forType: NSPasteboard.PasteboardType("app.kernova.sidebar-vm-row"))
        pasteboard.writeObjects([item])
        let belowRows = outline.rect(ofRow: outline.numberOfRows - 1).maxY + 100
        #expect(belowRows < outline.bounds.maxY)
        let drag = FakeDraggingInfo(
            window: outline.window,
            location: outline.convert(NSPoint(x: 100, y: belowRows), to: nil),
            pasteboard: pasteboard, source: outline)

        #expect(outline.draggingEntered(drag) == .move)
        #expect(outline.draggingUpdated(drag) == .move)
        #expect(outline.prepareForDragOperation(drag))
        #expect(outline.performDragOperation(drag))
        outline.concludeDragOperation(drag)

        #expect(library.entries.map(\.name) == ["A", "C", "B"])
    }

    // MARK: - Context menu

    @Test("A suspended VM's stop slot raises the discard confirmation once")
    func stopSlotOnASuspendedVMAsksOnce() async throws {
        let viewModel = makeViewModel()
        let presenter = MockVMLibraryPresenting()
        viewModel.presenter = presenter
        let suspended = viewModel.library.admitFixture(name: "Suspended", phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: suspended)
        let controller = SidebarViewController(viewModel: viewModel)
        let discard = try #require(
            menuItem("Discard Saved State…", in: controller.buildContextMenu(for: suspended)))

        _ = NSApp.sendAction(try #require(discard.action), to: discard.target, from: discard)
        // The item's action runs the verb in a task of its own.
        try await waitForChange { presenter.forceStopInstances.count == 1 }
        // Then let whatever is still queued run, so the count below reads
        // "exactly once" rather than "once so far".
        await drainMainQueue()

        #expect(presenter.forceStopInstances.map(\.id) == [suspended.id])
    }

    @Test("Context menu enables delete for a suspended VM but keeps Clone disabled")
    func contextMenuSuspendedEnablesDelete() throws {
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: instance)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        // The saved state is a file inside the bundle, so deleting takes no
        // Discard Saved State pass first.
        #expect(menuItem("Move to Trash…", in: menu)?.isEnabled == true)
        #expect(menuItem("Delete Immediately…", in: menu)?.isEnabled == true)
        // A clone of a suspended VM is taken with its slot on disk.
        #expect(menuItem("Clone as New Machine", in: menu)?.isEnabled == true)
    }

    @Test("Context menu disables delete for a live-paused VM")
    func contextMenuLivePausedDisablesDelete() {
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(phase: .livePaused(sessionID: UUID()))
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        #expect(instance.isLivePaused)
        #expect(menuItem("Move to Trash…", in: menu)?.isEnabled == false)
        #expect(menuItem("Delete Immediately…", in: menu)?.isEnabled == false)
    }

    /// A running VM whose guest's agents offer Stop Anyway, or not.
    private func runningInstance(
        in viewModel: VMLibraryViewModel, offeringStopAnyway offered: Bool
    ) -> VMInstance {
        let instance = viewModel.library.admitFixture(guestOS: .macOS, phase: .running(sessionID: UUID()))
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(
                peers: [], features: FeatureStatus.merge([]),
                powerIgnoringApps: offered ? .agent(.systemPeer) : .absent(.noAgent)))
        return instance
    }

    @Test(
        "Each power verb's Force form is its Option alternate and its Anyway form a plain item after it; with advanced options on, all six show in the menu bar's order",
        arguments: [false, true])
    func contextMenuPowerRows(advanced: Bool) throws {
        preferences.alwaysShowAdvancedOptions = advanced
        let viewModel = makeViewModel()
        let instance = runningInstance(in: viewModel, offeringStopAnyway: true)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        // Without Option AppKit shows Stop, Stop Anyway…, Restart, Restart
        // Anyway…, and holding it each Force form in its verb's row.
        let titles = menu.items.map(\.title)
        let stop = try #require(titles.firstIndex(of: "Stop"))
        #expect(
            Array(titles[stop...].prefix(6))
                == (advanced
                    ? ["Stop", "Stop Anyway…", "Force Stop…", "Restart", "Restart Anyway…", "Force Restart…"]
                    : ["Stop", "Force Stop…", "Stop Anyway…", "Restart", "Force Restart…", "Restart Anyway…"]))
        for title in ["Stop Anyway…", "Restart Anyway…"] {
            let anyway = try #require(menuItem(title, in: menu))
            #expect(!anyway.isAlternate, "\(title)")
            #expect(anyway.isEnabled, "\(title)")
        }
        for (primary, force) in [("Stop", "Force Stop…"), ("Restart", "Force Restart…")] {
            let primaryItem = try #require(menuItem(primary, in: menu))
            let forceItem = try #require(menuItem(force, in: menu))
            #expect(!primaryItem.isAlternate)
            #expect(forceItem.isAlternate == !advanced, "\(force)")
            #expect(forceItem.isEnabled, "\(force)")
            if !advanced {
                #expect(forceItem.keyEquivalentModifierMask == [.option])
                #expect(primaryItem.keyEquivalentModifierMask == [])
            }
        }
    }

    @Test(
        "Where not offered, neither Anyway form is in the menu at all, in either mode", arguments: [false, true])
    func contextMenuAnywayAbsentWhereNotOffered(advanced: Bool) throws {
        preferences.alwaysShowAdvancedOptions = advanced
        let viewModel = makeViewModel()
        let instance = runningInstance(in: viewModel, offeringStopAnyway: false)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        #expect(menuItem("Stop Anyway…", in: menu) == nil)
        #expect(menuItem("Restart Anyway…", in: menu) == nil)
        let titles = menu.items.map(\.title)
        let stop = try #require(titles.firstIndex(of: "Stop"))
        #expect(Array(titles[stop...].prefix(4)) == ["Stop", "Force Stop…", "Restart", "Force Restart…"])
    }

    @Test("On a paused guest both Anyway forms are listed in their places, disabled")
    func contextMenuAnywayDisabledWhilePaused() throws {
        preferences.alwaysShowAdvancedOptions = false
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(guestOS: .macOS, phase: .livePaused(sessionID: UUID()))
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(peers: [], features: FeatureStatus.merge([]), powerIgnoringApps: .agent(.systemPeer)))
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        let titles = menu.items.map(\.title)
        let stop = try #require(titles.firstIndex(of: "Stop"))
        #expect(titles[stop + 2] == "Stop Anyway…")
        #expect(titles[stop + 5] == "Restart Anyway…")
        #expect(menuItem("Stop Anyway…", in: menu)?.isEnabled == false)
        #expect(menuItem("Restart Anyway…", in: menu)?.isEnabled == false)
        // A paused guest is terminated where it is, so its Force forms stay live.
        #expect(menuItem("Force Restart…", in: menu)?.isEnabled == true)
    }

    /// The lifecycle items, in the order each expectation lists them.
    private static let lifecycleItems = [
        "Start", "Start in Recovery Mode…", "Pause", "Resume", "Stop", "Force Stop…", "Restart",
        "Suspend",
    ]

    /// Each lifecycle item's state in a macOS guest's menu: `E` listed and
    /// enabled, `D` listed and dimmed, `-` not listed. Dimmed is an item the
    /// VM takes once the operation holding it ends.
    @Test(
        "Each lifecycle item is listed and enabled as the VM's state decides",
        arguments: [
            (PhaseFixture.settled(.stopped), "EE------"),
            (.settled(.failed(message: "Boot failed.")), "E-------"),
            (.settled(.suspended), "---E----"),
            (.settled(.running(sessionID: UUID())), "--E-EEEE"),
            (.settled(.livePaused(sessionID: UUID())), "---EEEEE"),
            (
                .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped, boundSession: UUID()),
                "DD------"
            ),
            (
                .operating(.bringUp(.guestStart(.restoringSavedState)), from: .suspended, boundSession: UUID()),
                "---D----"
            ),
            // A base-status operation from rest dims what the VM takes once it ends.
            (.operating(.deletingSnapshot, from: .stopped), "DD------"),
            (.operating(.saving, from: .running(sessionID: UUID())), "--D-DDDD"),
            (.operating(.capturingSnapshot(.live), from: .running(sessionID: UUID())), "--D-DDDD"),
            // Operations that tolerate a stop leave both stops enabled.
            (.operating(.pausing, from: .running(sessionID: UUID())), "--D-EEED"),
            (.operating(.attachingUSB(registryID: 1), from: .running(sessionID: UUID())), "--D-EEED"),
            // A live-paused VM's Stop resumes it first, which the resume in
            // flight holds; its Force Stop is tolerated.
            (.operating(.resuming, from: .livePaused(sessionID: UUID())), "---DDEDD"),
            // A Force Stop in flight answers as the powered-off VM will.
            (.operating(.forceStopping, from: .running(sessionID: UUID())), "DD------"),
        ])
    func lifecycleItemsFollowTheVMsState(phase: PhaseFixture, expected: String) throws {
        preferences.alwaysShowAdvancedOptions = false
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(guestOS: .macOS, phase: phase.phase)
        switch phase {
        case .settled(.suspended), .operating(_, from: .suspended, _):
            try VMInstanceFixture.writeSaveFile(for: instance)
        default:
            break
        }
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        let actual = String(
            Self.lifecycleItems.map { title -> Character in
                guard let item = menuItem(title, in: menu) else { return "-" }
                return item.isEnabled ? "E" : "D"
            })
        #expect(actual == expected, "\(phase)")
        // Restart stands wherever Stop does, enabled alike, and Force
        // Restart… wherever Force Stop… does.
        let column = Array(actual)
        #expect(column[6] == column[4], "\(phase)")
        let forceRestart = menuItem("Force Restart…", in: menu).map { $0.isEnabled ? "E" : "D" } ?? "-"
        #expect(Character(forceRestart) == column[5], "\(phase)")
    }

    @Test("Restart in a running VM's menu restarts it")
    func restartItemRestartsTheVM() async throws {
        let viewModel = makeViewModel()
        let presenter = MockVMLibraryPresenting()
        viewModel.presenter = presenter
        let instance = viewModel.library.admitFixture(phase: .running(sessionID: UUID()))
        let firstSession = try #require(instance.activity.liveSessionID)
        let controller = SidebarViewController(viewModel: viewModel)
        let restart = try #require(menuItem("Restart", in: controller.buildContextMenu(for: instance)))

        _ = NSApp.sendAction(try #require(restart.action), to: restart.target, from: restart)
        try await waitForChange {
            instance.status == .running
                && instance.activity.liveSessionID.map { $0 != firstSession } == true
        }

        #expect(presenter.errors.isEmpty)
    }

    @Test("A running VM whose guest can write an external disk lists Take Snapshot dimmed")
    func contextMenuDimsTakeSnapshotWithAWritableExternalDisk() {
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(phase: .running(sessionID: UUID())) {
            $0.removableMedia = [RemovableMediaItem(path: "/Volumes/Data/Scratch.img", readOnly: false)]
        }
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        #expect(menuItem("Take Snapshot\u{2026}", in: menu)?.isEnabled == false)
    }

    @Test("Delete Immediately is the Option-alternate of Move to Trash (advanced options off)")
    func contextMenuDeleteImmediatelyIsOptionAlternate() {
        preferences.alwaysShowAdvancedOptions = false
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(phase: .stopped)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        // Both rows exist; AppKit collapses them into one visible "Move to Trash…" row
        // and swaps in "Delete Immediately…" only while Option is held.
        let trash = menuItem("Move to Trash…", in: menu)
        let deleteImmediately = menuItem("Delete Immediately…", in: menu)
        #expect(trash != nil)
        #expect(deleteImmediately != nil)
        #expect(deleteImmediately?.isAlternate == true)
        #expect(deleteImmediately?.keyEquivalentModifierMask == [.option])
        #expect(trash?.keyEquivalentModifierMask == [])
        // The alternate shares the primary's enablement gate.
        #expect(deleteImmediately?.isEnabled == true)
    }

    @Test("An arrival's row shows its name and label, and its menu offers only its Cancel")
    func arrivalRowShowsItsLabelAndOffersOnlyCancel() async throws {
        let viewModel = makeViewModel()
        let gate = GatedStep()
        let arrival = viewModel.library.beginGatedArrival(
            .cloning, named: "Copying", gate: gate)
        let controller = SidebarViewController(viewModel: viewModel)

        let cell = SidebarArrivalRowCellView()
        cell.configure(arrival: arrival, detail: { nil })
        #expect(cell.textField?.stringValue == "Copying")
        #expect(cell.toolTip == "Cloning\u{2026}")

        let menu = controller.buildContextMenu(for: arrival)

        // Nothing is at the destination until the write is published, so a
        // reveal would open Finder on a path that does not exist.
        #expect(titles(of: menu) == ["Cancel Clone"])

        #expect(arrival.requestCancel() == .cancelled)
        // The cell's observation applies on a later main-actor turn, with no
        // observable of its own to await.
        try await waitUntil { cell.toolTip == "Cancelling\u{2026}" }

        gate.release()
        await arrival.settle()
    }

    @Test("An unreadable bundle's row names it, warns in its tooltip, and offers only the check, Finder and the Trash")
    func unreadableRowOffersOnlyItsWayOut() throws {
        let viewModel = makeViewModel()
        let url = URL(fileURLWithPath: "/tmp/Library/VMs/Bad.kernova", isDirectory: true)
        let file = UnreadableConfigFile(
            location: .bundle(url, .configuration), owner: .virtualMachine("Bad VM"),
            problems: [
                ConfigProblem(
                    path: ConfigValuePath([.key("networkMode")]),
                    issue: .unrecognized(found: "plan9-mode"), repair: .useDefault("hostOnly"))
            ])
        let bundle = UnreadableVM(UnreadableBundle(url: url, file: file))
        let controller = SidebarViewController(viewModel: viewModel)

        let cell = SidebarUnreadableRowCellView()
        cell.configure(bundle: bundle)
        #expect(cell.textField?.stringValue == "Bad VM")
        #expect(
            cell.toolTip
                == "Kernova can\u{2019}t read this virtual machine\u{2019}s settings: "
                + "$.networkMode: \u{201C}plan9-mode\u{201D} is not a recognized value. "
                + "Choose File > Check Config Files\u{2026} to review it.")

        let menu = controller.buildContextMenu(for: bundle)
        #expect(titles(of: menu) == ["Check Config Files\u{2026}", "Show in Finder", "", "Move to Trash\u{2026}"])
        #expect(menu.items[2].isSeparatorItem)
    }

    @Test("A readable VM's row warns of a file it can't read and offers the check, until a read finds it readable")
    func readableRowWarnsOfAnUnreadableFile() async throws {
        let viewModel = makeViewModel()
        let files = InMemoryVMBundleFiles()
        // A snapshot with no `config.json` of its own is one a read refuses.
        let snapshot = VMSnapshot(
            name: "Snapshot", createdAt: Date(timeIntervalSince1970: 1_700_000_000), macAddress: nil)
        let instance = viewModel.library.admitFixture(
            name: "Dev", phase: .stopped,
            snapshots: VMSnapshotManifest(snapshots: [snapshot], currentID: nil), files: files)
        let controller = SidebarViewController(viewModel: viewModel)
        let cell = makeRow(instance: instance, isBusy: false)
        let check = "Check Config Files\u{2026}"

        #expect(
            cell.unreadableWarningToolTipForTesting
                == "Kernova can\u{2019}t read the settings of snapshot \u{201C}Snapshot\u{201D}. "
                + "Choose File > Check Config Files\u{2026} to review it.")
        #expect(titles(of: controller.buildContextMenu(for: instance)).contains(check))
        #expect(menuItem("Start", in: controller.buildContextMenu(for: instance))?.isEnabled == true)
        #expect(
            SidebarVMRowCellView.contentWidth(
                forName: "Dev", showsAgentAccessory: false, showsEphemeralAccessory: false,
                showsUnreadableWarning: true)
                > SidebarVMRowCellView.contentWidth(
                    forName: "Dev", showsAgentAccessory: false, showsEphemeralAccessory: false))

        files.setSnapshotConfiguration(instance.configuration, id: snapshot.id, at: instance.bundleURL)
        viewModel.library.recordUnreadableFiles(of: instance)

        // The cell's observation applies on a later main-actor turn.
        try await waitUntil { cell.unreadableWarningToolTipForTesting == nil }
        #expect(!titles(of: controller.buildContextMenu(for: instance)).contains(check))
    }

    // MARK: - Content-fit width

    @Test("emphasizedNameFont lays out as the font a selected source-list row draws")
    func emphasizedFontMatchesSelectedRowRendering() {
        // The oracle for the whole fix: the measuring font has to agree with what
        // a real source-list outline view puts on screen for a selected row. It
        // is asserted on laid-out width rather than font identity because AppKit
        // spells the same resolved face differently — it keeps the body text
        // style's usage attribute and adds an explicit 0.3 weight trait, where
        // the conversion names the emphasized text style — so the two fonts are
        // the same `.SFNS-Semibold` at the same size but are not `==`.
        let name = "Ubuntu Desktop 26.04"
        let probe = SelectedRowFontProbe(instance: VMInstanceFixture.make(name: name))

        guard let label = probe.selectedRowLabel() else {
            Issue.record("Expected the probe outline view to vend a configured row cell")
            return
        }
        guard
            let drawn = label.cell?.attributedStringValue.attribute(
                .font, at: 0, effectiveRange: nil) as? NSFont
        else {
            Issue.record("Expected the selected row's drawn string to carry a font")
            return
        }

        let renderedWidth = ceil(label.fittingSize.width)
        let measuring = SidebarVMRowCellView.emphasizedNameFont
        #expect(drawn.fontName == measuring.fontName)
        #expect(drawn.pointSize == measuring.pointSize)
        // The load-bearing property: the snap width is only right if the font it
        // measures with lays the name out to the width the row renders it at.
        #expect(measuredWidth(of: name, at: measuring) == renderedWidth)
        // Discriminating. `NSFontManager.convert` returns its input untouched
        // when that input already carries the trait, so a body font that ever
        // went bold would silently make the conversion a no-op; the regular
        // weight measures this name narrower, which fails here.
        #expect(measuredWidth(of: name, at: Typography.body) < renderedWidth)
        // Also keeps the probe — which the outline view references weakly — alive
        // across every assertion above.
        #expect(probe.outlineView.selectedRow == 0)
    }

    @Test("contentWidth measures names at the weight a selected row draws them")
    func contentWidthUsesEmphasizedWeight() {
        // A source-list outline view draws the selected row's name in the
        // emphasized variant of its font, so a fit width measured at the regular
        // weight leaves the selected name's tail under the trailing accessory.
        let emphasized = NSFontManager.shared.convert(Typography.body, toHaveTrait: .boldFontMask)
        #expect(emphasized != Typography.body)

        let long = "An extremely long virtual machine name"
        let short = "W"

        // The row chrome is identical for both names, so differencing the two
        // content widths leaves exactly the two measured name widths.
        func contentWidth(_ name: String) -> CGFloat {
            SidebarVMRowCellView.contentWidth(
                forName: name, showsAgentAccessory: false, showsEphemeralAccessory: false)
        }
        let measuredDelta = contentWidth(long) - contentWidth(short)

        #expect(
            measuredDelta
                == measuredWidth(of: long, at: emphasized)
                - measuredWidth(of: short, at: emphasized))
        // Discriminating: the emphasized weight is genuinely wider here, so the
        // assertion above fails if the measurement falls back to the body font.
        #expect(
            measuredDelta
                > measuredWidth(of: long, at: Typography.body)
                - measuredWidth(of: short, at: Typography.body))
    }

    @Test("contentWidth reserves a slot for each accessory when both show")
    func contentWidthBothAccessories() {
        let plain = SidebarVMRowCellView.contentWidth(
            forName: "Test VM", showsAgentAccessory: false, showsEphemeralAccessory: false)
        let both = SidebarVMRowCellView.contentWidth(
            forName: "Test VM", showsAgentAccessory: true, showsEphemeralAccessory: true)
        #expect(
            both - plain
                == (Spacing.small + SidebarEphemeralBadgeView.width)
                + (Spacing.small + SidebarAgentStatusButtonView.width))
    }

    // MARK: - View loading

    @Test("An arrival's row becomes its VM's row when it settles, keeping its place and selection")
    func settlingArrivalReloadsIntoAVMRow() async throws {
        let viewModel = makeViewModel()
        let before = viewModel.library.admitFixture(name: "Before")
        let gate = GatedStep()
        let arrival = viewModel.library.beginGatedArrival(named: "Arriving", gate: gate)
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        #expect((outline.item(atRow: 1) as? SidebarRow)?.entry.vm === before)
        let row = try #require(outline.item(atRow: 2) as? SidebarRow)
        #expect(row.entry.arrival === arrival)
        #expect(viewModel.selectedID == arrival.id)
        // The outline view offers no observable to await its selection by.
        try await waitUntil { outline.selectedRow == 2 }
        #expect(outline.view(atColumn: 0, row: 2, makeIfNecessary: true) is SidebarArrivalRowCellView)

        gate.release()
        let instance = try #require(await arrival.settle())

        try await waitUntil { row.entry.vm === instance }
        try await waitUntil {
            (outline.view(atColumn: 0, row: 2, makeIfNecessary: false) as? SidebarVMRowCellView)?
                .textField?.stringValue == instance.name
        }
        #expect(outline.numberOfRows == 3)
        #expect(outline.item(atRow: 2) as? SidebarRow === row)
        #expect(outline.selectedRow == 2)
        #expect(viewModel.selectedID == arrival.id)
    }
}

/// A minimal source-list `NSOutlineView` holding one configured VM row, used to
/// read back the font AppKit actually draws that row's name in once selected.
///
/// Window-less and never displayed: `reloadData`, selecting the row and a layout
/// pass are enough for AppKit to install the emphasized string, so the probe
/// stays synchronous and needs no run-loop spin.
@MainActor
private final class SelectedRowFontProbe: NSObject, NSOutlineViewDataSource,
    NSOutlineViewDelegate
{
    let outlineView = NSOutlineView()
    private let instance: VMInstance

    init(instance: VMInstance) {
        self.instance = instance
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = 280
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.style = .sourceList
        outlineView.headerView = nil
        outlineView.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        outlineView.dataSource = self
        outlineView.delegate = self
    }

    /// The name label of the single row, with that row selected.
    func selectedRowLabel() -> NSTextField? {
        outlineView.reloadData()
        outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        outlineView.layoutSubtreeIfNeeded()
        let cell = outlineView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        return (cell as? SidebarVMRowCellView)?.textField
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? 1 : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        instance
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

    func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        let cell = SidebarVMRowCellView()
        cell.configure(
            instance: instance,
            isRenaming: false,
            installPromptDisabled: { true },
            agentDiskControl: { nil },
            agentNudgeDismissible: { false },
            isBusy: { false },
            detail: { nil },
            tags: { [] },
            onCommitRename: { _ in },
            onCancelRename: {},
            onAgentDiskControl: {},
            onDismissAgentNudge: {}
        )
        return cell
    }
}

/// A drag session the test drives through the outline view's own
/// `NSDraggingDestination` methods, from a fixed point over it.
@MainActor
final class FakeDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation = .move
    let draggingLocation: NSPoint
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(window: NSWindow?, location: NSPoint, pasteboard: NSPasteboard, source: Any?) {
        draggingDestinationWindow = window
        draggingLocation = location
        draggingPasteboard = pasteboard
        draggingSource = source
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}
