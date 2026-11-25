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
    // MARK: Presentation

    @Test("Row 3, macOS: a session agent that connected this session and left reads disconnected, never warning")
    func sessionAgentGoneReadsDisconnected() async throws {
        let instance = Self.instance(guestOS: .macOS, session: "1.0")
        var session = Self.peer(1, standing: .current)
        session.os = .macOS
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([session]))
        instance.publishAgentHubSnapshotForTesting(Self.snapshot([], away: [(session, false)]))
        #expect(instance.agentPresentation?.status == .connecting(expected: "1.0"))
        instance.agentAbsenceGrace = .milliseconds(10)
        instance.startAgentAbsenceWatch()
        try await instance.agentAbsenceTimerForTesting?.joined()
        #expect(instance.agentPresentation?.status == .disconnected(last: "1.0"))
        #expect(instance.agentPresentation?.status.kind == .disconnected)
        #expect(instance.agentPresentation?.windowLines == [.init(title: "Session agent", state: "Disconnected")])
        #expect(
            VMCommandCore.agentLines(of: instance) == [
                VMAgentLine(role: .session, user: nil, version: "1.0", status: .disconnected)
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
    func windowAndInfoAgree() async throws {
        let instance = Self.linuxInstance(system: "1.0")
        instance.agentAbsenceGrace = .milliseconds(10)
        instance.startAgentAbsenceWatch()
        try await instance.agentAbsenceTimerForTesting?.joined()
        #expect(instance.warnedMissingAgents.map(\.scope) == [.system])
        defer { instance.sessionContext?.cancelAgentAbsenceWatchdog() }

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
                VMAgentLine(role: .session, user: "erin", version: "1.0", status: .current),
                VMAgentLine(role: .session, user: "pbear", version: "1.0", status: .current),
                VMAgentLine(role: .session, user: "bob", version: "1.0", status: .connecting),
                VMAgentLine(role: .session, user: "alice", version: "0.9", status: .updating),
                VMAgentLine(role: .system, user: nil, version: "1.0", status: .expectedMissing),
            ])
    }
}
