import AppKit
import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

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

    private func makeViewModel(storageService: MockVMStorageService = MockVMStorageService())
        -> VMLibraryViewModel
    {
        VMLibraryViewModel(
            storageService: storageService,
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            fileSystem: MockFileSystem(),
            downloadsDirectory: nil,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(), arpTable: ScriptedARPTable(), entitlements: .entitled
        )
    }

    /// The sidebar badge gate with the app-wide install prompt left on, which is
    /// every case but the ones exercising that preference.
    private func visibleAgentStatus(for instance: VMInstance) -> AgentStatus? {
        SidebarVMRowCellView.visibleAgentStatus(for: instance, installPromptDisabled: false)
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

    // MARK: - Status icon color

    @Test("statusDisplayNSColor maps each lifecycle state")
    func statusColorMapping() {
        let instance = VMInstanceFixture.make(phase: .stopped)
        // Concrete gray (not `.secondaryLabelColor`) so the OS icon keeps its
        // stopped color on the selection highlight instead of inverting to white.
        #expect(instance.statusDisplayNSColor == .systemGray)

        instance.activity.placeForTesting(.running(sessionID: UUID()))
        #expect(instance.statusDisplayNSColor == .systemGreen)

        instance.activity.placeForTesting(.failed(message: "Test failure"))
        #expect(instance.statusDisplayNSColor == .systemRed)

        instance.activity.placeForTesting(.operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped))
        #expect(instance.statusDisplayNSColor == .systemOrange)
    }

    @Test("statusDisplayNSColor is orange for a suspended VM")
    func statusColorSuspended() {
        let suspended = VMInstanceFixture.make(phase: .suspended)
        #expect(suspended.status == .suspended)
        #expect(suspended.statusDisplayNSColor == .systemOrange)
    }

    // MARK: - Agent indicator gating

    @Test("Agent indicator hidden for Linux guests")
    func agentHiddenForLinux() {
        let instance = VMInstanceFixture.make(guestOS: .linux, phase: .running(sessionID: UUID()))
        #expect(visibleAgentStatus(for: instance) == nil)
    }

    @Test("Agent indicator shows .waiting for a running macOS VM without an agent")
    func agentWaitingVisibleForRunningMac() {
        let instance = VMInstanceFixture.make(guestOS: .macOS, phase: .running(sessionID: UUID()))
        #expect(visibleAgentStatus(for: instance) == .waiting)
    }

    @Test("Agent indicator suppressed once the install nudge is dismissed")
    func agentSuppressedWhenDismissed() {
        let instance = VMInstanceFixture.make(
            guestOS: .macOS, phase: .running(sessionID: UUID()),
            hostState: VMHostState(agentInstallNudgeDismissed: true))
        #expect(visibleAgentStatus(for: instance) == nil)
    }

    @Test("Agent indicator suppressed for a stopped macOS VM")
    func agentSuppressedWhenStopped() {
        // Neither a VM that has never had an agent nor one that has: with no
        // live control channel, `.waiting` means "unknown", not "not installed".
        let fresh = VMInstanceFixture.make(guestOS: .macOS, phase: .stopped)
        #expect(visibleAgentStatus(for: fresh) == nil)

        let seen = VMInstanceFixture.make(guestOS: .macOS, phase: .stopped) {
            $0.lastSeenAgentVersion = "1.2.3"
        }
        #expect(visibleAgentStatus(for: seen) == nil)
    }

    @Test(
        "Agent indicator suppressed outside a live session",
        arguments: [
            PhaseFixture.operating(
                .bringUp(.guestStart(.starting(recovery: false))), from: .stopped, boundSession: UUID()),
            .operating(.saving, from: .running(sessionID: UUID())),
            .operating(.bringUp(.guestStart(.restoringSavedState)), from: .suspended, boundSession: UUID()),
            .settled(.failed(message: "Boot failed.")),
            .settled(.initialBoot),
        ]
    )
    func agentSuppressedWhenNotInLiveSession(phase: PhaseFixture) {
        let instance = VMInstanceFixture.make(guestOS: .macOS, phase: phase.phase)
        #expect(visibleAgentStatus(for: instance) == nil)
    }

    @Test("Agent indicator suppressed for a suspended VM")
    func agentSuppressedWhenSuspended() {
        let instance = VMInstanceFixture.make(guestOS: .macOS, phase: .suspended)  // no live VM
        #expect(instance.isSuspended)
        #expect(visibleAgentStatus(for: instance) == nil)
    }

    /// The live-session gate must not swallow the *louder* agent states — only
    /// the `.waiting` install nudge is dismissible, so a gate that over-reached
    /// would silently drop the "didn't reconnect" affordance.
    @Test("Agent indicator surfaces .expectedMissing on a running VM")
    func agentExpectedMissingVisibleWhenRunning() {
        let library = makeWiredLibrary()
        let instance = library.registerFixture(guestOS: .macOS, phase: .running(sessionID: UUID())) {
            $0.lastSeenAgentVersion = "1.2.3"
        }
        instance.beginSessionContextForTesting().agentExpectedButMissing = true
        #expect(
            visibleAgentStatus(for: instance)
                == .expectedMissing(expected: "1.2.3")
        )

        // Even a dismissed install nudge doesn't suppress it — the dismissal
        // gate is scoped to `.waiting`.
        library.editHostState(of: instance) { $0.agentInstallNudgeDismissed = true }
        #expect(
            visibleAgentStatus(for: instance)
                == .expectedMissing(expected: "1.2.3")
        )
    }

    @Test("The app-wide preference suppresses .waiting without touching the per-VM flag")
    func agentSuppressedWhenPromptDisabledAppWide() {
        let instance = VMInstanceFixture.make(guestOS: .macOS, phase: .running(sessionID: UUID()))
        #expect(
            SidebarVMRowCellView.visibleAgentStatus(for: instance, installPromptDisabled: true)
                == nil)
        // The per-VM flag is overridden, never written: turning the preference
        // back on must restore what this VM was set to.
        #expect(instance.hostState.agentInstallNudgeDismissed == false)
        #expect(visibleAgentStatus(for: instance) == .waiting)
    }

    /// The app-wide preference carries the same scope as the per-VM switch —
    /// only the gentle install nudge.
    ///
    /// A gate that over-reached would silence the "didn't reconnect" and
    /// "update available" affordances app-wide.
    @Test("The app-wide preference leaves the louder agent states alone")
    func agentLouderStatesSurviveAppWideDisable() {
        let missing = VMInstanceFixture.make(guestOS: .macOS, phase: .running(sessionID: UUID())) {
            $0.lastSeenAgentVersion = "1.2.3"
        }
        missing.beginSessionContextForTesting().agentExpectedButMissing = true
        #expect(
            SidebarVMRowCellView.visibleAgentStatus(for: missing, installPromptDisabled: true)
                == .expectedMissing(expected: "1.2.3"))
    }

    // MARK: - Row busy state

    /// The cell holds its instance weakly, so the caller keeps `instance` alive:
    /// binding a temporary would leave the row on a deallocated VM, and its
    /// observation loop registering nothing.
    private func makeRow(instance: VMInstance, isBusy: Bool) -> SidebarVMRowCellView {
        let cell = SidebarVMRowCellView()
        cell.configure(
            instance: instance,
            isRenaming: false,
            installPromptDisabled: { false },
            isBusy: { isBusy },
            detail: { nil },
            tags: { [] },
            onCommitRename: { _, _ in },
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
        _ = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(
            guestOS: .macOS, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting()
        let cell = makeRow(instance: instance, isBusy: false)
        let badge = try #require(firstSubview(SidebarAgentStatusButtonView.self, in: cell))
        #expect(!badge.isHidden)
        #expect(badge.status == .waiting)
        #expect(!badge.isInstallerMounted)

        viewModel.toggleGuestAgentDisk(on: instance)
        #expect(instance.hasGuestAgentInstallerMounted)
        #expect(instance.agentStatus == .waiting)

        // The cell's observation applies on a later main-actor turn, with no
        // observable of its own to await.
        try await waitUntil { badge.isInstallerMounted }
    }

    /// The preference lives in Settings, so it changes while every row is up.
    @Test("The agent badge follows the app-wide install-prompt preference")
    func agentBadgeFollowsAppWidePreference() async throws {
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(
            guestOS: .macOS, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting()
        let cell = SidebarVMRowCellView()
        cell.configure(
            instance: instance,
            isRenaming: false,
            installPromptDisabled: { viewModel.agentInstallPromptDisabled },
            isBusy: { false },
            detail: { nil },
            tags: { [] },
            onCommitRename: { _, _ in },
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

    /// Re-arming an observation reports only changes made *after* it registers,
    /// so anything that moved while the sidebar was off screen — a collapsed
    /// split item, a closed main window — arrives unobserved.
    @Test("Appearing lists the VMs added while the sidebar was off screen")
    func appearingAppliesOffScreenChanges() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Alpha")
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        controller.viewDidAppear()
        let outline = try #require(firstSubview(NSOutlineView.self, in: controller.view))
        #expect(outline.numberOfRows == 2)

        controller.viewWillDisappear()
        let beta = viewModel.library.admitFixture(name: "Beta")
        controller.viewDidAppear()

        #expect(outline.numberOfRows == 3)
        #expect((outline.item(atRow: 2) as? SidebarRow)?.entry.vm === beta)
    }

    // MARK: - Inline rename

    /// The row's name label, which is also the box a rename opens.
    private func nameLabel(in cell: SidebarVMRowCellView) throws -> InlineEditableLabel {
        try #require(firstSubview(InlineEditableLabel.self, in: cell))
    }

    private func makeRenamingRow(
        instance: VMInstance, onCommitRename: @escaping (String, Bool) -> Void = { _, _ in }
    ) -> SidebarVMRowCellView {
        let cell = SidebarVMRowCellView()
        cell.configure(
            instance: instance,
            isRenaming: true,
            installPromptDisabled: { false },
            isBusy: { false },
            detail: { nil },
            tags: { [] },
            onCommitRename: onCommitRename,
            onCancelRename: {},
            onAgentDiskControl: {},
            onDismissAgentNudge: {})
        return cell
    }

    /// During `reloadData` the row is configured — rename and all — before it
    /// joins the outline view's window, so the focus has to be re-established
    /// when it does.
    @Test("A rename armed off-window takes focus once the row joins one")
    func renameArmedOffWindowTakesFocusOnJoin() throws {
        let instance = VMInstanceFixture.make()
        let cell = makeRenamingRow(instance: instance)
        let label = try nameLabel(in: cell)

        #expect(cell.isRenaming)
        #expect(label.isEditable)
        #expect(label.currentEditor() == nil)

        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = cell

        #expect(label.currentEditor() != nil)
        #expect(cell.isRenaming)
    }

    /// The controller restores sidebar focus only for a keyboard Return, so the
    /// flag has to survive the trip out of the shared label.
    @Test("A Return-terminated rename reports that it ended by Return")
    func renameCommitReportsEndedByReturn() throws {
        let instance = VMInstanceFixture.make()
        var commits: [(name: String, endedByReturn: Bool)] = []
        let cell = makeRenamingRow(instance: instance) { commits.append(($0, $1)) }
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = cell
        let label = try nameLabel(in: cell)

        label.currentEditor()?.string = "Renamed"
        label.stringValue = "Renamed"
        label.controlTextDidEndEditing(
            Notification(
                name: NSControl.textDidEndEditingNotification, object: label,
                userInfo: ["NSTextMovement": NSTextMovement.return.rawValue]))

        #expect(commits.count == 1)
        #expect(commits.first?.name == "Renamed")
        #expect(commits.first?.endedByReturn == true)
        #expect(!cell.isRenaming)
    }

    /// A recycled row carries typed text belonging to the VM it used to show,
    /// so the reuse teardown must drop it rather than commit it.
    @Test("Recycling a row mid-rename commits nothing")
    func recyclingARenamingRowCommitsNothing() throws {
        let instance = VMInstanceFixture.make()
        var commits = 0
        let cell = makeRenamingRow(instance: instance) { _, _ in commits += 1 }
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
        #expect(viewModel.activeRename == .sidebar(alpha.id))
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

    @Test("An arrival's cell becomes a VM cell when it settles")
    func arrivalCellBecomesVMCell() async throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Before")
        let gate = GatedStep()
        let arrival = viewModel.library.beginGatedArrival(named: "Arriving", gate: gate)
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        #expect(outline.view(atColumn: 0, row: 2, makeIfNecessary: true) is SidebarArrivalRowCellView)

        gate.release()
        let instance = try #require(await arrival.settle())

        try await waitUntil {
            (outline.view(atColumn: 0, row: 2, makeIfNecessary: false) as? SidebarVMRowCellView)?
                .textField?.stringValue == instance.name
        }
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

    @Test("Context menu for a guest running macOS 12 offers only Clone as Exact Copy")
    func contextMenuMontereyGuestOffersOnlyAnExactCopy() {
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(guestOS: .macOS, phase: .stopped) {
            $0.lastSeenGuestOSVersion = "12.7.6"
        }
        let controller = SidebarViewController(viewModel: viewModel)

        let menuTitles = titles(of: controller.buildContextMenu(for: instance))

        #expect(menuTitles.filter { $0.hasPrefix("Clone") } == ["Clone as Exact Copy"])
    }

    @Test("Context menu for a stopped VM offers Start and enables management")
    func contextMenuStopped() {
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(phase: .stopped)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)
        let menuTitles = titles(of: menu)

        #expect(menuTitles.contains("Start"))
        #expect(!menuTitles.contains("Pause"))
        #expect(!menuTitles.contains("Stop"))
        #expect(menuItem("Rename", in: menu)?.isEnabled == true)
        #expect(menuItem("Clone as New Machine", in: menu)?.isEnabled == true)
        #expect(menuItem("Move to Trash…", in: menu)?.isEnabled == true)
        // A cold capture is offered while stopped; Suspend is not.
        #expect(menuItem("Take Snapshot…", in: menu)?.isEnabled == true)
        #expect(!menuTitles.contains("Suspend"))
    }

    @Test("Context menu for a running VM offers Pause/Stop/Suspend and disables editing")
    func contextMenuRunning() {
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(phase: .running(sessionID: UUID()))
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)
        let menuTitles = titles(of: menu)

        #expect(menuTitles.contains("Pause"))
        #expect(menuTitles.contains("Stop"))
        #expect(menuTitles.contains("Suspend"))
        #expect(!menuTitles.contains("Start"))
        #expect(menuItem("Clone as New Machine", in: menu)?.isEnabled == true)
        #expect(menuItem("Move to Trash…", in: menu)?.isEnabled == false)
        #expect(menuItem("Rename", in: menu)?.isEnabled == true)
    }

    @Test("Context menu keeps Clone enabled while a different VM is being copied")
    func contextMenuCloneIgnoresAnotherVMsCopy() async {
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(name: "Settled", phase: .stopped)
        let gate = GatedStep()
        let copying = viewModel.library.beginGatedArrival(
            .cloning, named: "Copying", gate: gate)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        // Overlapping clones and imports are a supported case — the copy in
        // flight belongs to another VM and says nothing about this one.
        #expect(viewModel.arrivals.map(\.id) == [copying.id])
        #expect(menuItem("Clone as New Machine", in: menu)?.isEnabled == true)

        gate.release()
        await copying.settle()
    }

    @Test("Context menu for a suspended VM offers Discard Saved State, not Stop/Suspend")
    func contextMenuSuspended() throws {
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(phase: .suspended)
        // A suspend slot on disk: every predicate a suspended VM is judged by
        // reads the file, not the status.
        try VMInstanceFixture.writeSaveFile(for: instance)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)
        let menuTitles = titles(of: menu)

        #expect(menuTitles.contains("Discard Saved State…"))
        #expect(menuTitles.contains("Resume"))
        #expect(!menuTitles.contains("Force Stop…"))
        #expect(!menuTitles.contains("Stop"))
        #expect(!menuTitles.contains("Suspend"))
        // The suspend slot itself can be captured, with no VZ work.
        #expect(menuTitles.contains("Take Snapshot…"))
    }

    /// One slot, one command: the title says what the VM's state makes of a
    /// stop, and the consent a discard needs is the refusal the verb raises.
    @Test("The stop slot dispatches the same command under either title")
    func stopSlotDispatchesOneCommand() throws {
        let viewModel = makeViewModel()
        let running = viewModel.library.admitFixture(name: "Running", phase: .running(sessionID: UUID()))
        let suspended = viewModel.library.admitFixture(name: "Suspended", phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: suspended)
        let controller = SidebarViewController(viewModel: viewModel)
        let runningMenu = controller.buildContextMenu(for: running)

        let stop = menuItem("Stop", in: runningMenu)
        let discard = menuItem(
            "Discard Saved State…", in: controller.buildContextMenu(for: suspended))

        #expect(stop?.action != nil)
        #expect(discard?.action == stop?.action)
        // Force Stop is a command of its own, which is why it keeps its own item.
        #expect(menuItem("Force Stop…", in: runningMenu)?.action != stop?.action)
    }

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

    @Test("Force Stop is the Option-alternate of Stop on a running VM (advanced options off)")
    func contextMenuForceStopIsOptionAlternate() {
        preferences.alwaysShowAdvancedOptions = false
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(phase: .running(sessionID: UUID()))
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        // Both rows exist in the item array; AppKit collapses them into one visible
        // "Stop" row and swaps in "Force Stop" only while Option is held.
        let stop = menuItem("Stop", in: menu)
        let forceStop = menuItem("Force Stop…", in: menu)
        #expect(stop != nil)
        #expect(forceStop != nil)
        // Keyless Option-reveal: the alternate carries [.option] and isAlternate, and
        // the primary's default [.command] mask is cleared so AppKit merges the pair.
        #expect(forceStop?.isAlternate == true)
        #expect(forceStop?.keyEquivalentModifierMask == [.option])
        #expect(stop?.keyEquivalentModifierMask == [])
    }

    @Test("Force Stop is a plain always-visible item when advanced options are on")
    func contextMenuForceStopVisibleWhenAdvanced() {
        preferences.alwaysShowAdvancedOptions = true
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(phase: .running(sessionID: UUID()))
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        let forceStop = menuItem("Force Stop…", in: menu)
        #expect(menuItem("Stop", in: menu) != nil)
        #expect(forceStop != nil)
        #expect(forceStop?.isAlternate == false)
    }

    @Test(
        "A VM coming up offers neither stop — Virtualization takes a termination from neither",
        arguments: [
            PhaseFixture.operating(
                .bringUp(.guestStart(.starting(recovery: false))), from: .stopped, boundSession: UUID()),
            .operating(.bringUp(.guestStart(.restoringSavedState)), from: .suspended, boundSession: UUID()),
        ])
    func contextMenuOffersNoStopWhileVirtualizationWouldRefuseOne(phase: PhaseFixture) {
        preferences.alwaysShowAdvancedOptions = false
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(phase: phase.phase)
        let controller = SidebarViewController(viewModel: viewModel)

        let menuTitles = titles(of: controller.buildContextMenu(for: instance))

        #expect(!menuTitles.contains("Stop"), "\(phase)")
        #expect(!menuTitles.contains("Force Stop…"), "\(phase)")
    }

    @Test(
        "A live VM held by a save or capture lists both stops, dimmed until it ends",
        arguments: [
            PhaseFixture.operating(.saving, from: .running(sessionID: UUID())),
            .operating(.capturingSnapshot(.live), from: .running(sessionID: UUID())),
        ])
    func contextMenuDimsStopWhileAnOperationHoldsALiveVM(phase: PhaseFixture) {
        preferences.alwaysShowAdvancedOptions = false
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(phase: phase.phase)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        // Busy, not inapplicable: each is taken once the operation ends.
        #expect(menuItem("Stop", in: menu)?.isEnabled == false, "\(phase)")
        #expect(menuItem("Force Stop…", in: menu)?.isEnabled == false, "\(phase)")
        #expect(menuItem("Suspend", in: menu)?.isEnabled == false, "\(phase)")
    }

    /// The lifecycle items, in the order each expectation lists them.
    private static let lifecycleItems = [
        "Start", "Start in Recovery Mode…", "Pause", "Resume", "Stop", "Force Stop…", "Suspend",
    ]

    /// Each lifecycle item's state in a macOS guest's menu: `E` listed and
    /// enabled, `D` listed and dimmed, `-` not listed. Dimmed is an item the
    /// VM takes once the operation holding it ends.
    @Test(
        "Each lifecycle item is listed and enabled as the VM's state decides",
        arguments: [
            (PhaseFixture.settled(.stopped), "EE-----"),
            (.settled(.failed(message: "Boot failed.")), "E------"),
            (.settled(.suspended), "---E---"),
            (.settled(.running(sessionID: UUID())), "--E-EEE"),
            (.settled(.livePaused(sessionID: UUID())), "---EEEE"),
            (
                .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped, boundSession: UUID()),
                "DD-----"
            ),
            // A base-status operation from rest dims what the VM takes once it ends.
            (.operating(.deletingSnapshot, from: .stopped), "DD-----"),
            (.operating(.saving, from: .running(sessionID: UUID())), "--D-DDD"),
            (.operating(.capturingSnapshot(.live), from: .running(sessionID: UUID())), "--D-DDD"),
            // Operations that tolerate a stop leave both stops enabled.
            (.operating(.pausing, from: .running(sessionID: UUID())), "--D-EED"),
            (.operating(.attachingUSB(registryID: 1), from: .running(sessionID: UUID())), "--D-EED"),
            // A live-paused VM's Stop resumes it first, which the resume in
            // flight holds; its Force Stop is tolerated.
            (.operating(.resuming, from: .livePaused(sessionID: UUID())), "---DDED"),
            // A Force Stop in flight answers as the powered-off VM will.
            (.operating(.forceStopping, from: .running(sessionID: UUID())), "DD-----"),
        ])
    func lifecycleItemsFollowTheVMsState(phase: PhaseFixture, expected: String) throws {
        preferences.alwaysShowAdvancedOptions = false
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(guestOS: .macOS, phase: phase.phase)
        if case .settled(.suspended) = phase {
            try VMInstanceFixture.writeSaveFile(for: instance)
        }
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        let actual = String(
            Self.lifecycleItems.map { title -> Character in
                guard let item = menuItem(title, in: menu) else { return "-" }
                return item.isEnabled ? "E" : "D"
            })
        #expect(actual == expected, "\(phase)")
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

    @Test("A capture of a stopped VM offers no Force Stop — there is no VM to terminate")
    func contextMenuNoForceStopDuringAColdCapture() {
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(
            phase: .operating(.capturingSnapshot(.stopped), from: .stopped))
        let controller = SidebarViewController(viewModel: viewModel)

        let menuTitles = titles(of: controller.buildContextMenu(for: instance))

        #expect(!menuTitles.contains("Force Stop…"))
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

    @Test("Delete Immediately is a plain always-visible item when advanced options are on")
    func contextMenuDeleteImmediatelyVisibleWhenAdvanced() {
        preferences.alwaysShowAdvancedOptions = true
        let viewModel = makeViewModel()
        let instance = viewModel.library.admitFixture(phase: .stopped)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        let deleteImmediately = menuItem("Delete Immediately…", in: menu)
        #expect(menuItem("Move to Trash…", in: menu) != nil)
        #expect(deleteImmediately != nil)
        #expect(deleteImmediately?.isAlternate == false)
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

    // MARK: - Content-fit width

    @Test("contentWidth grows with name length")
    func contentWidthGrowsWithName() {
        let short = SidebarVMRowCellView.contentWidth(
            forName: "A", showsAgentAccessory: false, showsEphemeralAccessory: false)
        let long = SidebarVMRowCellView.contentWidth(
            forName: "A much longer virtual machine name", showsAgentAccessory: false,
            showsEphemeralAccessory: false)
        #expect(long > short)
    }

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

    @Test("contentWidth adds the agent accessory width and gap")
    func contentWidthAccessoryDelta() {
        let withoutBadge = SidebarVMRowCellView.contentWidth(
            forName: "Test VM", showsAgentAccessory: false, showsEphemeralAccessory: false)
        let withBadge = SidebarVMRowCellView.contentWidth(
            forName: "Test VM", showsAgentAccessory: true, showsEphemeralAccessory: false)
        // The accessory adds its 16pt width plus the small inter-element gap.
        #expect(withBadge - withoutBadge == Spacing.small + 16)
    }

    @Test("contentWidth adds the ephemeral accessory width and gap")
    func contentWidthEphemeralAccessoryDelta() {
        let plain = SidebarVMRowCellView.contentWidth(
            forName: "Test VM", showsAgentAccessory: false, showsEphemeralAccessory: false)
        let withEphemeral = SidebarVMRowCellView.contentWidth(
            forName: "Test VM", showsAgentAccessory: false, showsEphemeralAccessory: true)
        #expect(withEphemeral - plain == Spacing.small + SidebarEphemeralBadgeView.width)
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

    @Test("widthToFitLongestRow is nil with no VMs")
    func fitWidthNilWhenEmpty() {
        let viewModel = makeViewModel()
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        #expect(controller.widthToFitLongestRow() == nil)
    }

    @Test("widthToFitLongestRow grows with the longest VM name")
    func fitWidthTracksLongestName() {
        let shortModel = makeViewModel()
        shortModel.library.admitFixture(name: "VM")
        let shortController = SidebarViewController(viewModel: shortModel)
        shortController.loadViewIfNeeded()
        shortController.view.layoutSubtreeIfNeeded()

        let longModel = makeViewModel()
        longModel.library.admitFixture(name: "An extremely long virtual machine name")
        let longController = SidebarViewController(viewModel: longModel)
        longController.loadViewIfNeeded()
        longController.view.layoutSubtreeIfNeeded()

        guard let shortWidth = shortController.widthToFitLongestRow(),
            let longWidth = longController.widthToFitLongestRow()
        else {
            Issue.record("Expected a fit width for both controllers")
            return
        }
        #expect(longWidth > shortWidth)
    }

    // MARK: - View loading

    @Test("Outline view loads the group with its VM rows expanded")
    func outlineViewLoadsRows() {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Alpha")
        viewModel.library.admitFixture(name: "Beta")
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        guard let outline = firstSubview(NSOutlineView.self, in: controller.view) else {
            Issue.record("Expected an NSOutlineView in the sidebar view tree")
            return
        }
        // One group row plus the two VM rows (group expanded by default).
        #expect(outline.numberOfRows == 3)
        #expect(outline.item(atRow: 0) is SidebarSection)
        #expect((outline.item(atRow: 1) as? SidebarRow)?.entry.vm?.name == "Alpha")
    }

    @Test("An arrival's row becomes its VM's row when it settles, keeping its place and selection")
    func settlingArrivalReloadsIntoAVMRow() async throws {
        let viewModel = makeViewModel()
        let before = viewModel.library.admitFixture(name: "Before")
        let gate = GatedStep()
        let arrival = viewModel.library.beginGatedArrival(named: "Arriving", gate: gate)
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        controller.viewDidAppear()
        let outline = try #require(firstSubview(NSOutlineView.self, in: controller.view))
        #expect((outline.item(atRow: 1) as? SidebarRow)?.entry.vm === before)
        let row = try #require(outline.item(atRow: 2) as? SidebarRow)
        #expect(row.entry.arrival === arrival)
        #expect(viewModel.selectedID == arrival.id)
        // The outline view offers no observable to await its selection by.
        try await waitUntil { outline.selectedRow == 2 }

        gate.release()
        let instance = try #require(await arrival.settle())

        try await waitUntil { row.entry.vm === instance }
        #expect(outline.numberOfRows == 3)
        #expect(outline.item(atRow: 2) as? SidebarRow === row)
        #expect(outline.selectedRow == 2)
        #expect(viewModel.selectedID == arrival.id)
    }

    @Test("A cloned VM's arrival row becomes the clone's row")
    func clonedRowSettlesIntoTheClone() async throws {
        let storage = MockVMStorageService()
        let viewModel = makeViewModel(storageService: storage)
        let source = viewModel.library.admitFixture(name: "Source", guestOS: .macOS)
        // Registered with the mock storage so the view model's real
        // `VMDirectoryWatcher` — which fires on the clone's directory actually
        // landing on disk (the mock now creates it, matching production) —
        // doesn't mistake the never-persisted source for a bundle that vanished
        // and reconcile it away.
        storage.bundles[source.bundleURL] = source.configuration
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        controller.viewDidAppear()
        let outline = try #require(firstSubview(NSOutlineView.self, in: controller.view))

        viewModel.cloneVM(source)
        // The clone registers its arrival and is adopted in place under the
        // same identifier, so its settle is the second VM in the library.
        try await waitForChange { viewModel.instances.count == 2 }
        #expect(viewModel.arrivals.isEmpty)
        let clone = try #require(viewModel.instances.last)

        // The adoption reaches the outline through the projection's own
        // observation loop, which offers no test-facing signal to await.
        try await waitUntil { (outline.item(atRow: 2) as? SidebarRow)?.entry.vm === clone }
        #expect(outline.numberOfRows == 3)
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
            isBusy: { false },
            detail: { nil },
            tags: { [] },
            onCommitRename: { _, _ in },
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
