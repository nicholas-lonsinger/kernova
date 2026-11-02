import Foundation
import KernovaAgentCore
import KernovaAgentHost
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

    @Test("A log-forwarding toggle reaches every connection, and later ones are built with it")
    func logForwardingToggle() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        #expect(probe.policies == [VMInstance.agentHubPolicy(for: instance.configuration)])
        var toggled = instance.configuration
        toggled.agentLogForwardingEnabled.toggle()
        let policy = VMInstance.agentHubPolicy(for: toggled)
        #expect(policy.isEnabled(.logs) == toggled.agentLogForwardingEnabled)

        instance.applyLivePolicy(oldConfig: instance.configuration, newConfig: toggled)
        try await probe.changed.wait { probe.commands.contains(.setPolicy(policy)) }
        #expect(probe.connect())
        try await probe.changed.wait { probe.policies.count == 2 }
        #expect(probe.policies.last == policy)
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

    @Test("A Linux session with no hub transport has no agent channel, so no presentation")
    func linuxWithoutTransport() {
        let instance = VMInstanceFixture.make(guestOS: .linux, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting()
        #expect(instance.agentPresentation == nil)
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
        #expect(instance.agentPresentation?.hub?.peers.first?.title == "Session agent — pbear")
    }

    private static func peer(
        _ handle: UInt64, role: PeerRole = .sessionPeer, version: String = "1.0", standing: PeerSummary.Standing
    ) -> PeerSummary {
        PeerSummary(
            handle: PeerHandle(rawValue: handle), role: role, scope: role == .systemPeer ? .system : .user,
            os: .linux, sessionID: "2", userName: role == .systemPeer ? "" : "pbear", console: .on,
            versionLabel: version, standing: standing, isResponsive: true)
    }

    /// The snapshot of `peers` connected and `away` gone, the newest gone first.
    private static func snapshot(
        _ peers: [PeerSummary], away: [(PeerSummary, relaunching: Bool)] = []
    ) -> AgentHubSnapshot {
        let count = UInt64(away.count)
        return AgentHubSnapshot(
            peers: peers, features: FeatureStatus.merge([]),
            away: away.enumerated().map {
                AwayPeer(summary: $0.element.0, relaunching: $0.element.relaunching, order: count - UInt64($0.offset))
            })
    }

    /// A running Linux instance with its hub attached, whose configuration remembers `session` and `system`
    /// agent versions.
    private static func linuxInstance(session: String? = nil, system: String? = nil) -> VMInstance {
        let probe = AgentHubProbe()
        let instance = VMInstanceFixture.make(
            guestOS: .linux, phase: .running(sessionID: UUID()), agentConnector: probe
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
        instance.startAgentPostStartWatchdog()
        #expect(instance.agentPostStartTaskForTesting == nil)
    }

    @Test("Row 4, Linux: a remembered system peer missing past the grace warns, with the notice saying so once")
    func systemPeerEscalates() async {
        let instance = Self.linuxInstance(system: "1.0")
        instance.startAgentPostStartWatchdog()
        #expect(instance.agentPostStartTaskForTesting != nil)
        instance.cancelAgentPostStartWatchdog()
        instance.startAgentPostStartWatchdog(grace: .milliseconds(10))
        await instance.agentPostStartTaskForTesting?.value
        #expect(instance.agentPresentation?.status == .expectedMissing(expected: "1.0"))
        #expect(instance.missingAgentNoticesForTesting.count == 1)
        #expect(instance.missingAgentNoticesForTesting.first?.contains("system agent, last seen 1.0") == true)
    }

    @Test("Row 2, Linux: a session agent seen before but not this session warns, though the system peer is connected")
    func sessionAgentNotYetThisSessionWarns() async {
        let instance = Self.linuxInstance(session: "0.9", system: "1.0")
        instance.publishAgentHubSnapshotForTesting(
            Self.snapshot([Self.peer(2, role: .systemPeer, standing: .current)]))
        #expect(instance.agentPresentation?.status == .current(version: "1.0"))
        #expect(instance.agentPostStartTaskForTesting != nil)
        instance.cancelAgentPostStartWatchdog()
        instance.startAgentPostStartWatchdog(grace: .milliseconds(10))
        await instance.agentPostStartTaskForTesting?.value
        #expect(instance.agentPresentation?.status == .expectedMissing(expected: "0.9"))
        #expect(instance.missingAgentNoticesForTesting.count == 1)
        #expect(instance.missingAgentNoticesForTesting.first?.contains("login agent, last seen 0.9") == true)
        // Its user logs in: nothing is missing, and the warning clears.
        instance.publishAgentHubSnapshotForTesting(
            Self.snapshot([
                Self.peer(1, version: "0.9", standing: .current), Self.peer(2, role: .systemPeer, standing: .current),
            ]))
        #expect(instance.agentPresentation?.status == .current(version: "0.9"))
        #expect(instance.agentPostStartTaskForTesting == nil)
    }

    @Test("Row 3, Linux: a session agent that connected this session never warns once its user logs out")
    func sessionAgentLogoutNeverWarns() async {
        let instance = Self.linuxInstance(session: "1.0", system: "1.0")
        let session = Self.peer(1, standing: .current)
        let system = Self.peer(2, role: .systemPeer, standing: .current)
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([session, system]))
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([system], away: [(session, false)]))
        // Armed only to forget the away line.
        instance.cancelAgentPostStartWatchdog()
        instance.startAgentPostStartWatchdog(grace: .milliseconds(10))
        await instance.agentPostStartTaskForTesting?.value
        #expect(instance.agentPresentation?.status == .current(version: "1.0"))
        #expect(instance.missingAgentNoticesForTesting.isEmpty)
        #expect(instance.agentExpectedButMissing == false)
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
        #expect(instance.agentPostStartTaskForTesting != nil)
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
        #expect(instance.agentPostStartTaskForTesting == nil)
    }

    @Test("A peer relaunching into an update reads Updating… through the relaunch, waited for past the rollback")
    func updateRelaunchKeepsUpdating() {
        let instance = Self.linuxInstance()
        let updating = Self.peer(1, version: "0.9", standing: .outdated(offeredVersionLabel: "1.0", update: .updating))
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([updating]))
        #expect(instance.agentPresentation?.status == .updating(installed: "0.9", bundled: "1.0"))
        let relaunching = Self.snapshot([], away: [(updating, true)])
        instance.publishAgentHubSnapshotForTesting(relaunching)
        #expect(instance.agentPresentation?.status == .updating(installed: "0.9", bundled: "1.0"))
        #expect(instance.agentPresentation?.hub?.peers.map(\.state) == ["Updating\u{2026}"])
        #expect(instance.agentPostStartTaskForTesting != nil)
        #expect(
            VMInstance.agentArrivalGrace(base: .seconds(120), for: relaunching)
                == .seconds(120 + UpdateRollbackPolicy.latestRevertSeconds))
        #expect(
            VMInstance.agentArrivalGrace(base: .seconds(120), for: Self.snapshot([], away: [(updating, false)]))
                == .seconds(120))
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([Self.peer(2, standing: .current)]))
        #expect(instance.agentPresentation?.status == .current(version: "1.0"))
    }

    @Test("Rows 3 and 4 together: after a shutdown only the system peer warns, and its return clears it")
    func awayEscalates() async {
        let instance = Self.linuxInstance()
        let system = Self.peer(2, role: .systemPeer, standing: .current)
        let session = Self.peer(1, standing: .current)
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([session, system]))
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([], away: [(system, false), (session, false)]))
        instance.cancelAgentPostStartWatchdog()
        instance.startAgentPostStartWatchdog(grace: .milliseconds(10))
        await instance.agentPostStartTaskForTesting?.value
        #expect(instance.agentPresentation?.status == .expectedMissing(expected: "1.0"))
        #expect(instance.missingAgentNoticesForTesting.count == 1)
        #expect(instance.missingAgentNoticesForTesting.first?.contains("system agent") == true)
        #expect(instance.missingAgentNoticesForTesting.first?.contains("login agent") == false)
        // The system peer arriving clears it.
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([system]))
        #expect(instance.agentPresentation?.status == .current(version: "1.0"))
    }

    @Test(
        "A peer arriving on the bundled payload ejects the installer disk; one already there, or out of date, does not")
    func currentPeerArrivalFiresTheEject() {
        let instance = VMInstanceFixture.make(guestOS: .linux, phase: .running(sessionID: UUID()))
        var fired = 0
        instance.onAgentBecameCurrent = { fired += 1 }
        let outdated = Self.peer(1, standing: .outdated(offeredVersionLabel: "2.0", update: .unavailable))
        let current = Self.peer(2, standing: .current)

        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(peers: [outdated], features: FeatureStatus.merge([])))
        #expect(fired == 0)
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(peers: [current, outdated], features: FeatureStatus.merge([])))
        #expect(fired == 1)
        // The same peers again, or the current one alone, is no arrival.
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(peers: [current, outdated], features: FeatureStatus.merge([])))
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(peers: [current], features: FeatureStatus.merge([])))
        #expect(fired == 1)
        // A reconnect is a new peer.
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(peers: [Self.peer(3, standing: .current)], features: FeatureStatus.merge([])))
        #expect(fired == 2)
    }
}
