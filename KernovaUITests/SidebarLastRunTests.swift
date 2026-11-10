import AppKit
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI
@testable import KernovaVirtualization

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
            bundleProducts: .testing
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

    @Test("A VM at rest states its last run in minutes, hours, then calendar days, or that none is recorded")
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
        #expect(detail(instance("G")) == "No run recorded")
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
}
