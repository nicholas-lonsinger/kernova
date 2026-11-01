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

    private static func peer(_ handle: UInt64, standing: PeerSummary.Standing) -> PeerSummary {
        PeerSummary(
            handle: PeerHandle(rawValue: handle), role: .sessionPeer, scope: .user, os: .linux, sessionID: "2",
            userName: "pbear", console: .on, versionLabel: "1.0", standing: standing, isResponsive: true)
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
