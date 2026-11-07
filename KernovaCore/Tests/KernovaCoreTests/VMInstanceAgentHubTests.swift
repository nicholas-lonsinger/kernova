import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaAgentRuntime
import KernovaCommandModel
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// What `VMInstance`'s lifecycle drives its agent hub to do, seen through a
/// probe standing in for the hub's connections and transport.
@MainActor
@Suite("VMInstance agent hub", .caseScoped)
struct VMInstanceAgentHubTests {
    private static let logsOff = PolicySnapshot([FeaturePolicyValue(feature: .logs, enabled: false)])

    /// A running instance whose hub's transport is `probe`, with one connection accepted through it.
    private func connected(_ probe: AgentHubProbe, guestOS: VMGuestOS = .macOS) async throws -> VMInstance {
        let instance = VMInstanceFixture.make(
            guestOS: guestOS, phase: .running(sessionID: UUID()), agentConnector: probe)
        instance.beginSessionContextForTesting()
        instance.attachAgentTransport(probe)
        try await probe.changed.wait { probe.isStarted }
        #expect(probe.connect())
        return instance
    }

    @Test("A live pause freezes every connection, and resuming thaws it")
    func livePauseFreezes() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        guard case .running(let sessionID) = instance.phase else {
            Issue.record("not running: \(instance.phase)")
            return
        }

        instance.activity.placeForTesting(.livePaused(sessionID: sessionID))
        try await probe.changed.wait { probe.commands.contains(.setPeerFrozen(true)) }
        instance.activity.placeForTesting(.running(sessionID: sessionID))
        try await probe.changed.wait { probe.commands.last == .setPeerFrozen(false) }
        #expect(probe.commands.filter { $0 == .setPeerFrozen(true) }.count == 1)
    }

    @Test("DRAG's policy is drag and drop's setting, and a toggle of it reaches every connection")
    func dragPolicyFollowsDropFiles() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        #expect(probe.policies.last?.isEnabled(.drag) == instance.configuration.dropFilesEnabled)
        var toggled = instance.configuration
        toggled.dropFilesEnabled.toggle()
        let policy = instance.agentHubPolicy(for: toggled)
        #expect(policy.isEnabled(.drag) == toggled.dropFilesEnabled)
        #expect(policy.isEnabled(.logs) == toggled.agentLogForwardingEnabled)

        instance.applyLivePolicy(oldConfig: instance.configuration, newConfig: toggled)
        try await probe.changed.wait { probe.commands.contains(.setPolicy(policy)) }
    }

    @Test("A log-forwarding toggle reaches every connection, and later ones are built with it")
    func logForwardingToggle() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        #expect(probe.policies == [instance.agentHubPolicy(for: instance.configuration)])
        var toggled = instance.configuration
        toggled.agentLogForwardingEnabled.toggle()
        let policy = instance.agentHubPolicy(for: toggled)
        #expect(policy.isEnabled(.logs) == toggled.agentLogForwardingEnabled)

        instance.applyLivePolicy(oldConfig: instance.configuration, newConfig: toggled)
        try await probe.changed.wait { probe.commands.contains(.setPolicy(policy)) }
        #expect(probe.connect())
        try await probe.changed.wait { probe.policies.count == 2 }
        #expect(probe.policies.last == policy)
    }

    @Test("CLIPBOARD's policy carries the paste ceiling, and a change to it reaches every connection")
    func pasteCeilingChange() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let initial = try #require(probe.policies.first)
        #expect(
            ClipboardPolicyValue(initial)?.maxPasteBytes == UInt64(instance.preferences.clipboardMaxPasteBytes))

        // The setting is app-wide, so no configuration changes: the Settings pane's re-push carries it.
        let raised = 16 * 1024 * 1024 * 1024
        instance.preferences.clipboardMaxPasteBytes = raised
        instance.resendAgentPolicy()
        let policy = instance.agentHubPolicy(for: instance.configuration)
        #expect(ClipboardPolicyValue(policy)?.maxPasteBytes == UInt64(raised))
        try await probe.changed.wait { probe.commands.contains(.setPolicy(policy)) }
    }

    @Test("A session's end detaches the hub: its streams shut down and later connections are refused")
    func sessionEndDetaches() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)

        instance.handleSessionEvent(.guestDidStop)
        try await probe.changed.wait { probe.shutdowns == 1 }
        #expect(!probe.connect())
        #expect(probe.policies.count == 1)
    }

    @Test("Releasing an instance whose session is still live closes its hub and shuts its streams down")
    func deinitClosesALiveAttachment() async throws {
        let probe = AgentHubProbe()
        weak var released: VMInstance?
        do {
            let instance = VMInstanceFixture.make(guestOS: .macOS, agentConnector: probe)
            released = instance
            instance.agentHub.attach(probe, policy: Self.logsOff, republisher: GuestLogRepublisher(vmLabel: "VM"))
            try await probe.changed.wait { probe.isStarted }
            #expect(probe.connect())
        }
        #expect(released == nil)
        try await probe.changed.wait { probe.shutdowns == 1 }
        #expect(!probe.connect())
    }

    // MARK: Presentation

    @Test("A session with no hub transport has no agent channel, so no presentation", arguments: VMGuestOS.allCases)
    func withoutTransport(guestOS: VMGuestOS) {
        let instance = VMInstanceFixture.make(guestOS: guestOS, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting()
        #expect(instance.agentPresentation == nil)
        #expect(!instance.reachesGuestAgent)
    }

    @Test("A macOS session presents its session and system peers from the hub's snapshot, as a Linux one does")
    func macOSFollowsPublishedSnapshot() {
        let instance = Self.instance(guestOS: .macOS)
        var session = Self.peer(1, version: "1.0 (1)", standing: .current)
        session.os = .macOS
        var system = Self.peer(2, role: .systemPeer, version: "1.0 (1)", standing: .current)
        system.os = .macOS
        let snapshot = Self.snapshot([session, system])
        var arrived: [Set<GuestAgentScope>] = []
        instance.onCurrentAgentsArrived = { arrived.append($0) }

        instance.publishAgentHubSnapshotForTesting(snapshot)

        #expect(instance.agentPresentation == GuestAgentPresentation(hub: snapshot))
        #expect(instance.agentPresentation?.status == .current(version: "1.0 (1)"))
        #expect(
            instance.agentPresentation?.windowLines == [
                .init(title: "Session agent — pbear", state: "Up to date"),
                .init(title: "System service", state: "Up to date"),
            ])
        #expect(
            VMCommandCore.agentLines(of: instance) == [
                VMAgentLine(role: "session", user: "pbear", version: "1.0 (1)", status: "current"),
                VMAgentLine(role: "system", user: nil, version: "1.0 (1)", status: "current"),
            ])
        #expect(arrived == [[.login, .system]])
        #expect(instance.lastSeenAgentVersion == "1.0 (1)")
        #expect(instance.lastSeenSystemAgentVersion == "1.0 (1)")
    }

    @Test("Row 3, macOS: a session agent that connected this session and left reads disconnected, never warning")
    func sessionAgentGoneReadsDisconnected() async {
        let instance = Self.instance(guestOS: .macOS, session: "1.0")
        var session = Self.peer(1, standing: .current)
        session.os = .macOS
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([session]))
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([], away: [(session, false)]))
        #expect(instance.agentPresentation?.status == .connecting(expected: "1.0"))
        instance.agentAbsenceGrace = .milliseconds(10)
        instance.startAgentAbsenceWatch()
        await instance.agentAbsenceTimerForTesting?.value
        #expect(instance.agentPresentation?.status == .disconnected(last: "1.0"))
        #expect(instance.agentPresentation?.status.wireName == "disconnected")
        #expect(instance.agentPresentation?.windowLines == [.init(title: "Session agent", state: "Disconnected")])
        #expect(
            VMCommandCore.agentLines(of: instance) == [
                VMAgentLine(role: "session", user: nil, version: "1.0", status: "disconnected")
            ])
        #expect(instance.missingAgentNoticesForTesting.isEmpty)
        #expect(instance.agentExpectedButMissing == false)
        #expect(instance.agentAbsenceTimerForTesting == nil)
        // It comes back: connected again, and the line goes.
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([Self.peer(2, standing: .current)]))
        #expect(instance.agentPresentation?.status == .current(version: "1.0"))
        #expect(
            instance.agentPresentation?.windowLines == [.init(title: "Session agent — pbear", state: "Up to date")])
    }

    @Test("Row 2, macOS: a session agent seen before but not this session warns past the grace")
    func macOSSessionAgentNotYetThisSessionWarns() async {
        let instance = Self.instance(guestOS: .macOS, session: "0.9 (1)")
        #expect(instance.agentPresentation?.status == .connecting(expected: "0.9 (1)"))
        instance.agentAbsenceGrace = .milliseconds(10)
        instance.startAgentAbsenceWatch()
        await instance.agentAbsenceTimerForTesting?.value
        #expect(instance.agentPresentation?.status == .expectedMissing(expected: "0.9 (1)"))
        #expect(instance.missingAgentNoticesForTesting.first?.contains("login agent, last seen 0.9 (1)") == true)
    }

    @Test("A Linux session with the hub attached presents its snapshot, waiting with no agent")
    func linuxWithTransport() async throws {
        let probe = AgentHubProbe()
        let instance = VMInstanceFixture.make(
            guestOS: .linux, phase: .running(sessionID: UUID()), agentConnector: probe)
        instance.beginSessionContextForTesting()
        instance.attachAgentTransport(probe)
        #expect(instance.agentPresentation == GuestAgentPresentation(hub: .empty))
        #expect(instance.agentPresentation?.status == .waiting)
    }

    @Test("A Linux session's presentation follows the snapshot the hub publishes")
    func linuxFollowsPublishedSnapshot() {
        let probe = AgentHubProbe()
        let instance = VMInstanceFixture.make(
            guestOS: .linux, phase: .running(sessionID: UUID()), agentConnector: probe)
        instance.beginSessionContextForTesting()
        instance.attachAgentTransport(probe)
        let snapshot = AgentHubSnapshot(
            peers: [
                PeerSummary(
                    handle: PeerHandle(rawValue: 1), role: .sessionPeer, scope: .user, os: .linux, sessionID: "2",
                    userName: "pbear", console: .on, versionLabel: "1.0", standing: .current, isResponsive: true)
            ], features: FeatureStatus.merge([]))

        instance.publishAgentHubSnapshotForTesting(snapshot)

        #expect(instance.agentPresentation == GuestAgentPresentation(hub: snapshot))
        #expect(instance.agentPresentation?.status == .current(version: "1.0"))
        #expect(instance.agentPresentation?.agents.first?.title == "Session agent — pbear")
    }

    private static func peer(
        _ handle: UInt64, role: PeerRole = .sessionPeer, version: String = "1.0", standing: PeerSummary.Standing
    ) -> PeerSummary {
        PeerSummary(
            handle: PeerHandle(rawValue: handle), role: role, scope: role == .systemPeer ? .system : .user,
            os: .linux, sessionID: "2", userName: role == .systemPeer ? "" : "pbear", console: .on,
            versionLabel: version, standing: standing, isResponsive: true)
    }

    /// The snapshot of `peers` connected and `away` gone, the newest gone first, each gone now.
    private static func snapshot(
        _ peers: [PeerSummary], away: [(PeerSummary, relaunching: Bool)] = []
    ) -> AgentHubSnapshot {
        let count = UInt64(away.count)
        return snapshot(
            peers,
            away: away.enumerated().map {
                Self.away($0.element.0, relaunching: $0.element.relaunching, order: count - UInt64($0.offset))
            })
    }

    /// The snapshot of `peers` connected and `away` gone.
    private static func snapshot(_ peers: [PeerSummary], away: [AwayPeer]) -> AgentHubSnapshot {
        AgentHubSnapshot(peers: peers, features: FeatureStatus.merge([]), away: away)
    }

    /// `peer`, gone at `since`.
    private static func away(
        _ peer: PeerSummary, relaunching: Bool = false, order: UInt64, since: CoreInstant = SystemScheduler().now
    ) -> AwayPeer {
        AwayPeer(summary: peer, relaunching: relaunching, order: order, since: since)
    }

    /// The rollback window a peer relaunching into an update is waited for on top of the grace.
    private static let rollback: Duration = .seconds(UpdateRollbackPolicy.latestRevertSeconds)

    /// A running Linux instance with its hub attached, whose configuration remembers `session` and `system`
    /// agent versions.
    private static func linuxInstance(session: String? = nil, system: String? = nil) -> VMInstance {
        instance(guestOS: .linux, session: session, system: system)
    }

    /// A running `guestOS` instance with its hub attached, whose configuration remembers `session` and
    /// `system` agent versions.
    private static func instance(guestOS: VMGuestOS, session: String? = nil, system: String? = nil) -> VMInstance {
        let probe = AgentHubProbe()
        let instance = VMInstanceFixture.make(
            guestOS: guestOS, phase: .running(sessionID: UUID()), agentConnector: probe
        ) { config in
            config.lastSeenAgentVersion = session
            config.lastSeenSystemAgentVersion = system
        }
        instance.beginSessionContextForTesting()
        instance.attachAgentTransport(probe)
        return instance
    }

    // MARK: Cold boot and the login screen

    @Test("A cold boot of a VM that has had an agent reads connecting until one arrives, never not installed")
    func coldBootRemembered() {
        let instance = Self.linuxInstance(session: "1.0", system: "1.0")
        #expect(instance.agentPresentation?.status == .connecting(expected: "1.0"))
        let sessionOnly = Self.linuxInstance(session: "0.9")
        #expect(sessionOnly.agentPresentation?.status == .connecting(expected: "0.9"))
    }

    @Test("Row 1, Linux: no agent ever seen arms nothing and the VM reads not installed")
    func neverHadAnAgent() {
        let instance = Self.linuxInstance()
        #expect(instance.agentPresentation?.status == .waiting)
        instance.startAgentAbsenceWatch()
        #expect(instance.agentAbsenceTimerForTesting == nil)
    }

    @Test("Row 4, Linux: a remembered system peer missing past the grace warns, with the notice saying so once")
    func systemPeerEscalates() async {
        let instance = Self.linuxInstance(system: "1.0")
        instance.startAgentAbsenceWatch()
        #expect(instance.agentAbsenceTimerForTesting != nil)
        instance.agentAbsenceGrace = .milliseconds(10)
        instance.startAgentAbsenceWatch()
        await instance.agentAbsenceTimerForTesting?.value
        #expect(instance.agentPresentation?.status == .expectedMissing(expected: "1.0"))
        #expect(instance.missingAgentNoticesForTesting.count == 1)
        #expect(instance.missingAgentNoticesForTesting.first?.contains("system agent, last seen 1.0") == true)
        #expect(
            instance.agentPresentation?.windowLines == [
                .init(title: "System service", state: "Didn\u{2019}t reconnect")
            ]
        )
        #expect(
            VMCommandCore.agentLines(of: instance) == [
                VMAgentLine(role: "system", user: nil, version: "1.0", status: "expectedMissing")
            ])
    }

    @Test("(c) Both agents missing past the grace: the popover and `kernova info` name each")
    func bothMissingNamedEverywhere() async {
        let instance = Self.linuxInstance(session: "0.9", system: "1.0")
        instance.agentAbsenceGrace = .milliseconds(10)
        instance.startAgentAbsenceWatch()
        await instance.agentAbsenceTimerForTesting?.value
        #expect(instance.agentPresentation?.status == .expectedMissing(expected: "0.9"))
        #expect(
            instance.agentPresentation?.windowLines == [
                .init(title: "Session agent", state: "Didn\u{2019}t reconnect; it starts when a user logs in"),
                .init(title: "System service", state: "Didn\u{2019}t reconnect"),
            ])
        #expect(
            VMCommandCore.agentLines(of: instance) == [
                VMAgentLine(role: "session", user: nil, version: "0.9", status: "expectedMissing"),
                VMAgentLine(role: "system", user: nil, version: "1.0", status: "expectedMissing"),
            ])
    }

    @Test("The window and `kernova info` list the same agents in the same order, each with its wire status")
    func windowAndInfoAgree() async {
        let instance = Self.linuxInstance(system: "1.0")
        instance.agentAbsenceGrace = .milliseconds(10)
        instance.startAgentAbsenceWatch()
        await instance.agentAbsenceTimerForTesting?.value
        #expect(instance.warnedMissingAgents.map(\.scope) == [.system])
        defer { instance.cancelAgentAbsenceWatchdog() }

        instance.agentAbsenceGrace = .seconds(60)
        var erin = Self.peer(4, standing: .current)
        erin.userName = "erin"
        var alice = Self.peer(1, version: "0.9", standing: .outdated(offeredVersionLabel: "1.0", update: .updating))
        alice.userName = "alice"
        var bob = Self.peer(2, standing: .current)
        bob.userName = "bob"
        let system = Self.peer(3, role: .systemPeer, standing: .current)
        instance.publishAgentHubSnapshotForTesting(
            Self.snapshot(
                [erin, Self.peer(5, standing: .current)],
                away: [(bob, relaunching: false), (alice, relaunching: true), (system, relaunching: false)]))
        #expect(instance.warnedMissingAgents.map(\.scope) == [.system])

        // The system scope's line stands in place of its away one.
        #expect(
            instance.agentPresentation?.windowLines == [
                .init(title: "Session agent — erin", state: "Up to date"),
                .init(title: "Session agent — pbear", state: "Up to date"),
                .init(title: "Session agent — bob", state: "Reconnecting\u{2026}"),
                .init(title: "Session agent — alice", state: "Updating\u{2026}"),
                .init(title: "System service", state: "Didn\u{2019}t reconnect"),
            ])
        #expect(
            VMCommandCore.agentLines(of: instance) == [
                VMAgentLine(role: "session", user: "erin", version: "1.0", status: "current"),
                VMAgentLine(role: "session", user: "pbear", version: "1.0", status: "current"),
                VMAgentLine(role: "session", user: "bob", version: "1.0", status: "connecting"),
                VMAgentLine(role: "session", user: "alice", version: "0.9", status: "updating"),
                VMAgentLine(role: "system", user: nil, version: "1.0", status: "expectedMissing"),
            ])
    }

    @Test("Row 2, Linux: a session agent seen before but not this session warns, though the system peer is connected")
    func sessionAgentNotYetThisSessionWarns() async {
        let instance = Self.linuxInstance(session: "0.9", system: "1.0")
        instance.publishAgentHubSnapshotForTesting(
            Self.snapshot([Self.peer(2, role: .systemPeer, standing: .current)]))
        #expect(instance.agentPresentation?.status == .current(version: "1.0"))
        #expect(instance.agentAbsenceTimerForTesting != nil)
        instance.agentAbsenceGrace = .milliseconds(10)
        instance.startAgentAbsenceWatch()
        await instance.agentAbsenceTimerForTesting?.value
        #expect(instance.agentPresentation?.status == .expectedMissing(expected: "0.9"))
        #expect(instance.missingAgentNoticesForTesting.count == 1)
        #expect(instance.missingAgentNoticesForTesting.first?.contains("login agent, last seen 0.9") == true)
        // Every surface names it: the popover's line, and `kernova info`'s.
        #expect(
            instance.agentPresentation?.windowLines.last
                == .init(title: "Session agent", state: "Didn\u{2019}t reconnect; it starts when a user logs in"))
        #expect(
            VMCommandCore.agentLines(of: instance) == [
                VMAgentLine(role: "system", user: nil, version: "1.0", status: "current"),
                VMAgentLine(role: "session", user: nil, version: "0.9", status: "expectedMissing"),
            ])
        // Its user logs in: nothing is missing, and the warning clears.
        instance.publishAgentHubSnapshotForTesting(
            Self.snapshot([
                Self.peer(1, version: "0.9", standing: .current), Self.peer(2, role: .systemPeer, standing: .current),
            ]))
        #expect(instance.agentPresentation?.status == .current(version: "0.9"))
        #expect(instance.agentAbsenceTimerForTesting == nil)
    }

    @Test("Row 3, Linux: a session agent that connected this session never warns once its user logs out")
    func sessionAgentLogoutNeverWarns() async {
        let instance = Self.linuxInstance(session: "1.0", system: "1.0")
        let session = Self.peer(1, standing: .current)
        let system = Self.peer(2, role: .systemPeer, standing: .current)
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([session, system]))
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([system], away: [(session, false)]))
        // Armed only to forget the away line.
        instance.agentAbsenceGrace = .milliseconds(10)
        instance.startAgentAbsenceWatch()
        await instance.agentAbsenceTimerForTesting?.value
        #expect(instance.agentPresentation?.status == .current(version: "1.0"))
        #expect(
            instance.agentPresentation?.windowLines == [
                .init(title: "System service", state: "Up to date"),
                .init(title: "Session agent", state: "Disconnected"),
            ])
        #expect(instance.missingAgentNoticesForTesting.isEmpty)
        #expect(instance.agentExpectedButMissing == false)
    }

    @Test("Uninstalled for everyone: past the grace the system service warns, the session agent disconnected beside it")
    func everyoneUninstallWarns() async {
        let instance = Self.instance(guestOS: .macOS)
        let session = Self.peer(1, standing: .current)
        let system = Self.peer(2, role: .systemPeer, standing: .current)
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([session, system]))
        instance.publishAgentHubSnapshotForTesting(
            Self.snapshot([], away: [(system, relaunching: false), (session, relaunching: false)]))
        instance.agentAbsenceGrace = .milliseconds(10)
        instance.startAgentAbsenceWatch()
        await instance.agentAbsenceTimerForTesting?.value
        #expect(instance.agentPresentation?.status == .expectedMissing(expected: "1.0"))
        #expect(
            instance.agentPresentation?.windowLines == [
                .init(title: "System service", state: "Didn\u{2019}t reconnect"),
                .init(title: "Session agent", state: "Disconnected"),
            ])
        #expect(instance.missingAgentNoticesForTesting.count == 1)
    }

    @Test("Each scope's connected peer is remembered as the session sees it")
    func remembersEachScope() {
        let instance = Self.linuxInstance()
        instance.publishAgentHubSnapshotForTesting(
            Self.snapshot([
                Self.peer(1, version: "2.0", standing: .current),
                Self.peer(2, role: .systemPeer, version: "2.1", standing: .current),
            ]))
        #expect(instance.lastSeenAgentVersion == "2.0")
        #expect(instance.lastSeenSystemAgentVersion == "2.1")
        #expect(instance.effectiveConfiguration.lastSeenSystemAgentVersion == "2.1")
    }

    @Test("A guest shutting down shows its agents reconnecting, never not installed, and arms the watchdog")
    func shutdownIsNotUninstalled() {
        let instance = Self.linuxInstance()
        let session = Self.peer(1, standing: .current)
        let system = Self.peer(2, role: .systemPeer, standing: .current)
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([session, system]))
        #expect(instance.agentPresentation?.status == .current(version: "1.0"))
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([system], away: [(session, false)]))
        #expect(instance.agentPresentation?.status == .current(version: "1.0"))
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([], away: [(system, false), (session, false)]))
        #expect(instance.agentPresentation?.status == .connecting(expected: "1.0"))
        #expect(instance.agentAbsenceTimerForTesting != nil)
    }

    @Test("A guest rebooting reads reconnecting until its agents return, then current, the watchdog disarmed")
    func rebootReturns() {
        let instance = Self.linuxInstance()
        let session = Self.peer(1, standing: .current)
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([session]))
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([], away: [(session, false)]))
        #expect(instance.agentPresentation?.status == .connecting(expected: "1.0"))
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([Self.peer(3, standing: .current)]))
        #expect(instance.agentPresentation?.status == .current(version: "1.0"))
        #expect(instance.agentAbsenceTimerForTesting == nil)
    }

    @Test("A peer relaunching into an update reads Updating… through the relaunch")
    func updateRelaunchKeepsUpdating() {
        let instance = Self.linuxInstance()
        let updating = Self.peer(1, version: "0.9", standing: .outdated(offeredVersionLabel: "1.0", update: .updating))
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([updating]))
        #expect(instance.agentPresentation?.status == .updating(installed: "0.9", bundled: "1.0"))
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([], away: [(updating, true)]))
        #expect(instance.agentPresentation?.status == .updating(installed: "0.9", bundled: "1.0"))
        #expect(instance.agentPresentation?.agents.map(\.state) == ["Updating\u{2026}"])
        #expect(instance.agentAbsenceTimerForTesting != nil)
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([Self.peer(2, standing: .current)]))
        #expect(instance.agentPresentation?.status == .current(version: "1.0"))
    }

    // MARK: Each absence's own allowance

    @Test("A system peer relaunching into an update is waited for through its rollback, past the Start's grace")
    func relaunchOutlastsTheStartGrace() throws {
        let instance = Self.linuxInstance(session: "0.9", system: "0.9")
        let grace = instance.agentAbsenceGrace
        instance.startAgentAbsenceWatch()
        let context = try #require(instance.sessionContext)
        let floor = try #require(context.agentAbsenceFloor)
        // Start: the session agent has not connected yet, so the login scope is waited for from the floor.
        #expect(context.agentAbsenceTimerDeadline == floor + grace)

        // The system peer connects, then leaves relaunching into an update.
        let updating = Self.peer(
            2, role: .systemPeer, version: "0.9", standing: .outdated(offeredVersionLabel: "1.0", update: .updating))
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([updating]))
        #expect(context.agentAbsenceTimerDeadline == floor + grace)
        let relaunching = Self.away(updating, relaunching: true, order: 1)
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([], away: [relaunching]))
        #expect(context.agentAbsenceTimerDeadline == floor + grace)

        // The session peer connects: nothing waits for the floor's grace any more, so nothing warns then; the
        // timer waits for the system peer's own rollback.
        let session = Self.peer(1, version: "0.9", standing: .current)
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([session], away: [relaunching]))
        #expect(context.agentAbsenceTimerDeadline == relaunching.since + grace + Self.rollback)
        #expect(relaunching.since + grace + Self.rollback > floor + grace)
        #expect(instance.warnedMissingAgents.isEmpty)
        #expect(instance.agentPresentation?.agents.map(\.state) == ["Up to date", "Updating\u{2026}"])

        // The rollback brings the system peer back: the timer is cancelled, and nothing warned.
        instance.publishAgentHubSnapshotForTesting(
            Self.snapshot([Self.peer(3, role: .systemPeer, version: "0.9", standing: .current), session]))
        #expect(instance.agentAbsenceTimerForTesting == nil)
        #expect(instance.missingAgentNoticesForTesting.isEmpty)
        #expect(instance.agentExpectedButMissing == false)
    }

    @Test("A scope that goes missing after another armed the timer warns only at its own deadline")
    func laterScopeGetsItsOwnDeadline() async throws {
        let instance = Self.linuxInstance(session: "0.9", system: "1.0")
        let grace = Duration.milliseconds(50)
        instance.agentAbsenceGrace = grace
        instance.startAgentAbsenceWatch()
        let context = try #require(instance.sessionContext)
        let floor = try #require(context.agentAbsenceFloor)
        let system = Self.peer(2, role: .systemPeer, standing: .current)
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([system]))
        // The system peer leaves well after the floor, and not into an update.
        let left = Self.away(system, order: 1, since: floor + .seconds(3_600))
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([], away: [left]))
        #expect(context.agentAbsenceTimerDeadline == floor + grace)
        defer { instance.cancelAgentAbsenceWatchdog() }

        // The floor's deadline warns the login scope alone; the system scope waits for its own.
        await instance.agentAbsenceTimerForTesting?.value
        #expect(instance.missingAgentNoticesForTesting.count == 1)
        #expect(instance.missingAgentNoticesForTesting.first?.contains("login agent") == true)
        #expect(instance.missingAgentNoticesForTesting.first?.contains("system agent") == false)
        #expect(instance.warnedMissingAgents.map(\.scope) == [.login])
        #expect(context.agentAbsenceTimerDeadline == left.since + grace)

        // A later absence of the system peer whose own deadline has passed warns it, in a notice of its own.
        let leftAgain = Self.away(
            system, order: 2, since: SystemScheduler().now.advanced(by: CoreDuration(.zero - grace)))
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([], away: [leftAgain]))
        await instance.agentAbsenceTimerForTesting?.value
        #expect(instance.missingAgentNoticesForTesting.count == 2)
        #expect(instance.missingAgentNoticesForTesting.last?.contains("system agent") == true)
        #expect(instance.missingAgentNoticesForTesting.last?.contains("login agent") == false)
        #expect(instance.warnedMissingAgents.map(\.scope) == [.login, .system])
        #expect(instance.agentAbsenceTimerForTesting == nil)
    }

    @Test("Once one scope has warned, another that goes missing is not shown as warned before its own deadline")
    func warningStaysPerScope() async throws {
        let instance = Self.linuxInstance(session: "0.9", system: "1.0")
        let grace = Duration.milliseconds(50)
        instance.agentAbsenceGrace = grace
        let system = Self.peer(2, role: .systemPeer, standing: .current)
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([system]))
        instance.startAgentAbsenceWatch()
        await instance.agentAbsenceTimerForTesting?.value
        #expect(instance.warnedMissingAgents.map(\.scope) == [.login])
        defer { instance.cancelAgentAbsenceWatchdog() }

        instance.agentAbsenceGrace = .seconds(60)
        let left = Self.away(system, order: 1)
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([], away: [left]))
        #expect(instance.warnedMissingAgents.map(\.scope) == [.login])
        #expect(
            instance.agentPresentation?.windowLines == [
                .init(title: "System service", state: "Reconnecting\u{2026}"),
                .init(title: "Session agent", state: "Didn\u{2019}t reconnect; it starts when a user logs in"),
            ])
        #expect(instance.sessionContext?.agentAbsenceTimerDeadline == left.since + .seconds(60))
        #expect(instance.missingAgentNoticesForTesting.count == 1)
    }

    @Test("Each away line expires at its own deadline: a relaunching peer that left first outlives a plain one")
    func awayLinesExpireSeparately() async throws {
        let instance = Self.linuxInstance()
        let grace = Duration.milliseconds(100)
        instance.agentAbsenceGrace = grace
        var alice = Self.peer(1, version: "0.9", standing: .outdated(offeredVersionLabel: "1.0", update: .updating))
        alice.userName = "alice"
        var bob = Self.peer(2, standing: .current)
        bob.userName = "bob"
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([bob, alice]))
        instance.startAgentAbsenceWatch()
        let aliceAway = Self.away(alice, relaunching: true, order: 1)
        let bobAway = Self.away(bob, order: 2)
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([], away: [bobAway, aliceAway]))
        let context = try #require(instance.sessionContext)
        #expect(context.agentAbsenceTimerDeadline == bobAway.since + grace)
        defer { instance.cancelAgentAbsenceWatchdog() }

        await instance.agentAbsenceTimerForTesting?.value
        #expect(instance.agentHubSnapshot.away == [aliceAway])
        #expect(
            instance.agentPresentation?.windowLines == [
                .init(title: "Session agent — alice", state: "Updating\u{2026}")
            ]
        )
        #expect(context.agentAbsenceTimerDeadline == aliceAway.since + grace + Self.rollback)
        #expect(instance.missingAgentNoticesForTesting.isEmpty)

        // The hub no longer listing the expired peer drops it from what the session remembers.
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([], away: [aliceAway]))
        #expect(context.expiredAwayOrders.isEmpty)
    }

    @Test("A resume restarts every pending allowance from the resume")
    func resumeRestartsAllowances() async throws {
        let instance = Self.linuxInstance(session: "0.9", system: "1.0")
        let grace = Duration.seconds(60)
        instance.agentAbsenceGrace = grace
        instance.startAgentAbsenceWatch()
        let context = try #require(instance.sessionContext)
        let floor = try #require(context.agentAbsenceFloor)
        let system = Self.peer(2, role: .systemPeer, standing: .current)
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([system]))
        let left = Self.away(system, order: 1)
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([], away: [left]))
        #expect(context.agentAbsenceTimerDeadline == floor + grace)
        defer { instance.cancelAgentAbsenceWatchdog() }

        // A pause cancels the timer, as the pause operation does.
        let sessionID = try #require(instance.liveSessionID)
        instance.activity.placeForTesting(.livePaused(sessionID: sessionID))
        instance.cancelAgentAbsenceWatchdog()
        instance.agentPresenceChanged()
        #expect(instance.agentAbsenceTimerForTesting == nil)

        let beforeResume = SystemScheduler().now
        try await instance.activity.perform(.resuming) { _ in .rest(.live(.running), ()) }
        let resumed = try #require(context.agentAbsenceFloor)
        #expect(resumed >= beforeResume)
        let pending = AgentAbsenceDeadlines.pending(
            presences: instance.agentScopePresences, away: [left], floor: resumed, grace: grace, warned: [],
            expired: [])
        #expect(Set(pending.map(\.subject)) == [.scope(.login), .scope(.system), .away(order: 1)])
        #expect(pending.allSatisfy { $0.deadline == resumed + grace })
        #expect(context.agentAbsenceTimerDeadline == resumed + grace)
    }

    @Test("Rows 3 and 4 together: after a shutdown only the system peer warns, and its return clears it")
    func awayEscalates() async {
        let instance = Self.linuxInstance()
        let system = Self.peer(2, role: .systemPeer, standing: .current)
        let session = Self.peer(1, standing: .current)
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([session, system]))
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([], away: [(system, false), (session, false)]))
        instance.agentAbsenceGrace = .milliseconds(10)
        instance.startAgentAbsenceWatch()
        await instance.agentAbsenceTimerForTesting?.value
        #expect(instance.agentPresentation?.status == .expectedMissing(expected: "1.0"))
        #expect(instance.missingAgentNoticesForTesting.count == 1)
        #expect(instance.missingAgentNoticesForTesting.first?.contains("system agent") == true)
        #expect(instance.missingAgentNoticesForTesting.first?.contains("login agent") == false)
        // The system peer arriving clears it.
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([system]))
        #expect(instance.agentPresentation?.status == .current(version: "1.0"))
    }

    @Test(
        "A peer arriving on the bundled payload reports its scope; one already there, or out of date, reports nothing")
    func currentPeerArrivalReportsItsScope() {
        let instance = VMInstanceFixture.make(guestOS: .linux, phase: .running(sessionID: UUID()))
        var arrivals: [Set<GuestAgentScope>] = []
        instance.onCurrentAgentsArrived = { arrivals.append($0) }
        let outdated = Self.peer(1, standing: .outdated(offeredVersionLabel: "2.0", update: .unavailable))
        let current = Self.peer(2, standing: .current)

        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(peers: [outdated], features: FeatureStatus.merge([])))
        #expect(arrivals.isEmpty)
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(peers: [current, outdated], features: FeatureStatus.merge([])))
        #expect(arrivals == [[.login]])
        // The same peers again, or the current one alone, is no arrival.
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(peers: [current, outdated], features: FeatureStatus.merge([])))
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(peers: [current], features: FeatureStatus.merge([])))
        #expect(arrivals == [[.login]])
        // A system peer arriving reports its own scope.
        let system = Self.peer(3, role: .systemPeer, standing: .current)
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(peers: [current, system], features: FeatureStatus.merge([])))
        #expect(arrivals == [[.login], [.system]])
        // A reconnect is a new peer.
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(peers: [Self.peer(4, standing: .current)], features: FeatureStatus.merge([])))
        #expect(arrivals == [[.login], [.system], [.login]])
    }
}
