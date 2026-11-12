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

    // MARK: Presentation

    @Test("A peer arrives current when it first stands current, on its connection or once the hub judges it")
    func peerArrivesWhenItTurnsCurrent() {
        let instance = Self.instance(guestOS: .linux)
        var arrived: [Set<GuestAgentScope>] = []
        instance.onCurrentAgentsArrived = { arrived.append($0) }

        // Connected before the hub's bundles loaded, so not yet judged.
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([Self.peer(1, standing: .notOffered)]))
        #expect(arrived.isEmpty)
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([Self.peer(1, standing: .current)]))
        #expect(arrived == [[.login]])
        // Still current, and joined by a system peer that connected current.
        instance.publishAgentHubSnapshotForTesting(
            Self.snapshot([Self.peer(2, role: .systemPeer, standing: .current), Self.peer(1, standing: .current)]))
        #expect(arrived == [[.login], [.system]])
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
}
