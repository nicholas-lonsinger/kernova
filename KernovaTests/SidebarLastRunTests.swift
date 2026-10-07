import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The sidebar's Last Run sort: the order it projects, the detail line it
/// states, and the shared clock that keeps a relative line current.
@Suite("Sidebar last-run sort", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct SidebarLastRunTests {
    private let preferences = makeTestPreferences()
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeViewModel() -> VMLibraryViewModel {
        VMLibraryViewModel(
            storageService: MockVMStorageService(),
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

    private func instance(
        _ name: String, phase: VMLifecyclePhase = .stopped, lastRun: TimeInterval? = nil
    ) -> VMInstance {
        VMInstanceFixture.make(
            name: name, phase: phase,
            hostState: VMHostState(lastRunAt: lastRun.map { Self.now.addingTimeInterval(-$0) }))
    }

    /// `instance` in a session that settled running `ago` seconds before ``now``.
    private func runningFor(_ ago: TimeInterval, _ instance: VMInstance) -> VMInstance {
        instance.beginSessionContextForTesting().runningSince = Self.now.addingTimeInterval(-ago)
        return instance
    }

    private func detail(_ instance: VMInstance) -> String {
        VMLibrarySort.lastRun.detail(for: .vm(instance), at: Self.now)
    }

    // MARK: - Order

    @Test("Live VMs sort first — another copy's included — then most recent, then never run, ties A→Z")
    func projectionOrder() {
        let held = instance("Held", lastRun: 7200)
        held.activity.recordOtherCopyHold(heldElsewhere: true)
        let entries: [LibraryEntry] = [
            .vm(instance("Never")),
            .vm(instance("Hour ago", lastRun: 3600)),
            // A live VM's record is its session's start, older than any ended run.
            .vm(instance("Running", phase: .running(sessionID: UUID()), lastRun: 86_400)),
            .vm(instance("Day ago", lastRun: 86_400)),
            .vm(held),
            .vm(instance("Minute ago", lastRun: 60)),
            .vm(instance("Also never")),
            .vm(instance("Paused", phase: .livePaused(sessionID: UUID()), lastRun: 86_400)),
        ]

        let layout = SidebarLayout.project(
            entries: entries, options: SidebarViewOptions(sort: .lastRun), context: .testing())
        let shown = layout.rowKeys.compactMap { key in entries.first { $0.id == key.entryID }?.name }

        #expect(
            shown == [
                "Held", "Paused", "Running", "Minute ago", "Hour ago", "Day ago", "Also never", "Never",
            ])
    }

    // MARK: - Detail

    @Test("A running session states how long it has run, to the minute below")
    func runningDetail() {
        let running = { self.instance("Running", phase: .running(sessionID: UUID())) }
        #expect(detail(runningFor(30, running())) == "Running for under a minute")
        #expect(detail(runningFor(12 * 60 + 59, running())) == "Running for 12 min")
        #expect(detail(runningFor(65 * 60, running())) == "Running for 1 hr, 5 min")
        #expect(detail(runningFor(26 * 3600, running())) == "Running for 1 day, 2 hr")
    }

    @Test("A live VM not running states its status in place of a last run")
    func liveNotRunningDetail() {
        let paused = runningFor(600, instance("Paused", phase: .livePaused(sessionID: UUID()), lastRun: 600))
        #expect(detail(paused) == "Paused")

        let held = instance("Held", lastRun: 7200)
        held.activity.recordOtherCopyHold(heldElsewhere: true)
        #expect(detail(held) == VMStatus.heldByAnotherCopyDisplayName)
    }

    @Test("A VM at rest states when it last ran, relative within a week; one never run says so")
    func atRestDetail() {
        #expect(detail(instance("A", lastRun: 30)) == "Last run just now")
        #expect(detail(instance("B", lastRun: 3 * 3600)) == "Last run 3 hours ago")
        #expect(detail(instance("C", lastRun: 26 * 3600)) == "Last run yesterday")
        #expect(detail(instance("D", lastRun: 3 * 86_400)) == "Last run 3 days ago")
        let longAgo = Self.now.addingTimeInterval(-10 * 86_400)
        #expect(
            detail(instance("E", lastRun: 10 * 86_400))
                == "Last run \(longAgo.formatted(date: .abbreviated, time: .omitted))")
        #expect(detail(instance("F")) == "Never run")
    }

    // MARK: - Clock

    @Test("A clock tick refreshes a row's relative detail with no model change")
    func clockRefreshesTheDetail() async throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(
            name: "A", preferences: preferences,
            hostState: VMHostState(lastRunAt: Self.now.addingTimeInterval(-2 * 3600)))
        viewModel.sidebarOptions.sort = .lastRun
        viewModel.sidebarOptions.showsDetails = true
        let clock = MinuteClock(now: Self.now)
        let controller = SidebarViewController(viewModel: viewModel, clock: clock)
        controller.loadViewIfNeeded()
        controller.viewDidAppear()
        controller.view.layoutSubtreeIfNeeded()
        let outline = try #require(firstSubview(NSOutlineView.self, in: controller.view))
        let cell = try #require(
            outline.view(atColumn: 0, row: 1, makeIfNecessary: true) as? SidebarVMRowCellView)
        let shows = { (text: String) in
            allSubviews(NSTextField.self, in: cell).contains { !$0.isHidden && $0.stringValue == text }
        }
        #expect(shows("Last run 2 hours ago"))

        clock.advance(to: Self.now.addingTimeInterval(86_400))

        try await waitUntil { shows("Last run yesterday") }
    }
}
