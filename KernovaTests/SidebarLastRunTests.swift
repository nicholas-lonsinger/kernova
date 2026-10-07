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
    /// Wednesday 2027-01-13 09:00 in ``calendar``.
    private static let now = Date(timeIntervalSince1970: 1_799_830_800)
    /// A calendar whose days do not move with the machine running the tests.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

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
        VMLibrarySort.lastRun.detail(for: .vm(instance), at: Self.now, calendar: Self.calendar)
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

    @Test("A running session states when it started, in whole minutes, hours or calendar days")
    func runningDetail() {
        let running = { self.instance("Running", phase: .running(sessionID: UUID())) }
        #expect(detail(runningFor(30, running())) == "Started just now")
        #expect(detail(runningFor(12 * 60 + 59, running())) == "Started 12 minutes ago")
        #expect(detail(runningFor(65 * 60, running())) == "Started 1 hour ago")
        #expect(detail(runningFor(26 * 3600, running())) == "Started yesterday")
    }

    @Test("A live VM not running states its status in place of a last run")
    func liveNotRunningDetail() {
        let paused = runningFor(600, instance("Paused", phase: .livePaused(sessionID: UUID()), lastRun: 600))
        #expect(detail(paused) == "Paused")

        let held = instance("Held", lastRun: 7200)
        held.activity.recordOtherCopyHold(heldElsewhere: true)
        #expect(detail(held) == VMStatus.heldByAnotherCopyDisplayName)
    }

    @Test("A VM at rest states when it last ran — minutes and hours within a day, then calendar days")
    func atRestDetail() {
        #expect(detail(instance("A", lastRun: 30)) == "Last run just now")
        #expect(detail(instance("B", lastRun: 3 * 3600 + 59 * 60)) == "Last run 3 hours ago")
        #expect(detail(instance("C", lastRun: 26 * 3600)) == "Last run yesterday")
        // Monday 10:00, seen Wednesday 09:00: under two full days, two calendar days.
        #expect(detail(instance("D", lastRun: 47 * 3600)) == "Last run 2 days ago")
        #expect(detail(instance("E", lastRun: 6 * 86_400)) == "Last run 6 days ago")
        let weekAgo = Self.now.addingTimeInterval(-7 * 86_400)
        var dateStyle = Date.FormatStyle(date: .abbreviated, time: .omitted)
        dateStyle.timeZone = Self.calendar.timeZone
        #expect(detail(instance("F", lastRun: 7 * 86_400)) == "Last run \(weekAgo.formatted(dateStyle))")
        #expect(detail(instance("G")) == "Never run")
    }

    @Test("Under a day reads in hours even across midnight; a 25-hour day's own date never reads as yesterday")
    func dayBoundaries() {
        // Tuesday 23:00 seen Wednesday 09:00.
        #expect(detail(instance("A", lastRun: 10 * 3600)) == "Last run 10 hours ago")
        // 2026-11-01, the US clocks fall back: 00:10 seen 23:50 the same day.
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let lateThatDay = Date(timeIntervalSince1970: 1_793_605_800)  // 2026-11-01 23:50 PST
        let run = VMInstanceFixture.make(
            name: "B", hostState: VMHostState(lastRunAt: lateThatDay.addingTimeInterval(-24 * 3600 - 40 * 60)))
        #expect(
            VMLibrarySort.lastRun.detail(for: .vm(run), at: lateThatDay, calendar: pacific) == "Last run 24 hours ago")
    }

    // MARK: - Clock

    /// A sidebar under the Last Run sort with Show Details on, driven by
    /// `clock`, and the first row's cell; `admit` adds the one VM it lists.
    private func sidebarCell(
        clock: MinuteClock, admit: (VMLibraryViewModel) -> Void
    ) throws -> (controller: SidebarViewController, shows: (String) -> Bool) {
        let viewModel = makeViewModel()
        admit(viewModel)
        viewModel.sidebarOptions.sort = .lastRun
        viewModel.sidebarOptions.showsDetails = true
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
        return (controller, shows)
    }

    @Test("A clock tick refreshes an at-rest row's last run with no model change")
    func clockRefreshesTheLastRun() async throws {
        let clock = MinuteClock(now: Self.now)
        let (controller, shows) = try sidebarCell(clock: clock) { viewModel in
            viewModel.library.admitFixture(
                name: "A", preferences: preferences,
                hostState: VMHostState(lastRunAt: Self.now.addingTimeInterval(-2 * 3600)))
        }
        #expect(shows("Last run 2 hours ago"))

        clock.advance(to: Self.now.addingTimeInterval(3600))

        try await waitUntil { shows("Last run 3 hours ago") }
        withExtendedLifetime(controller) {}
    }

    @Test("A clock tick refreshes a running row's start with no model change")
    func clockRefreshesTheStart() async throws {
        let clock = MinuteClock(now: Self.now)
        let (controller, shows) = try sidebarCell(clock: clock) { viewModel in
            let running = viewModel.library.admitFixture(
                name: "A", phase: .running(sessionID: UUID()), preferences: preferences)
            running.beginSessionContextForTesting().runningSince = Self.now.addingTimeInterval(-12 * 60)
        }
        #expect(shows("Started 12 minutes ago"))

        clock.advance(to: Self.now.addingTimeInterval(60))

        try await waitUntil { shows("Started 13 minutes ago") }
        withExtendedLifetime(controller) {}
    }
}
