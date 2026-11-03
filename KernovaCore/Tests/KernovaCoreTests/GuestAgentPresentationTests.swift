import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaAgentRuntime
import KernovaCommandModel
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore

@Suite("GuestAgentPresentation", .caseScoped)
struct GuestAgentPresentationTests {
    private static func peer(
        _ handle: UInt64, role: PeerRole = .sessionPeer, userName: String = "pbear", version: String = "1.0",
        standing: PeerSummary.Standing = .current, isResponsive: Bool = true
    ) -> PeerSummary {
        PeerSummary(
            handle: PeerHandle(rawValue: handle), role: role, scope: role == .systemPeer ? .system : .user,
            os: .linux, sessionID: role == .systemPeer ? "" : "2", userName: role == .systemPeer ? "" : userName,
            console: .on, versionLabel: version, standing: standing, isResponsive: isResponsive)
    }

    private static func snapshot(
        _ peers: [PeerSummary], logs: Availability<Data>? = nil, update: Availability<Data>? = nil
    ) -> AgentHubSnapshot {
        let rows = [logs.map { (feature: FeatureID.logs, status: $0) }, update.map { (feature: .update, status: $0) }]
        let features =
            logs == nil && update == nil ? FeatureStatus.merge([]) : FeatureStatusTable(rows.compactMap { $0 })
        return AgentHubSnapshot(peers: peers, features: features)
    }

    @Test(
        "The macOS agent's presentation is its status alone",
        arguments: [
            AgentStatus.waiting, .current(version: "0.9.2"), .outdated(installed: "0.9.1", bundled: "0.9.2"),
            .unresponsive(version: "0.9.2"), .connecting(expected: "0.9.2"), .expectedMissing(expected: "0.9.2"),
        ])
    func macOSAdapter(status: AgentStatus) {
        let presentation = GuestAgentPresentation(macOSAgent: status)
        #expect(presentation.status == status)
        #expect(presentation.hub == nil)
    }

    @Test("With no agent connected, the hub's presentation is waiting, and its Status and logs rows say why")
    func hubWithNoPeers() {
        let presentation = GuestAgentPresentation(hub: .empty)
        #expect(presentation.status == .waiting)
        #expect(presentation.hub?.windowLines == [])
        #expect(
            presentation.hub?.capabilities == [
                .init(title: "Status", isAvailable: false, detail: "No Kernova agent is connected."),
                .init(title: "Guest logs in Console", isAvailable: false, detail: "No Kernova agent is connected."),
                .init(title: "Automatic agent updates", isAvailable: false, detail: "No Kernova agent is connected."),
            ])
    }

    @Test("One current session agent is a line naming its user, and the Status row is connected")
    func hubWithOneCurrentPeer() {
        let presentation = GuestAgentPresentation(hub: Self.snapshot([Self.peer(1)], logs: .available(Data())))
        #expect(presentation.status == .current(version: "1.0"))
        #expect(presentation.hub?.windowLines == [.init(title: "Session agent — pbear", state: "Up to date")])
        #expect(
            presentation.hub?.capabilities == [
                .init(title: "Status", isAvailable: true, detail: "Connected"),
                .init(title: "Guest logs in Console", isAvailable: true, detail: "On"),
                .init(title: "Automatic agent updates", isAvailable: false, detail: "This agent doesn't offer it."),
            ])
    }

    @Test(
        "The automatic updates row reads the merged UPDATE status: on, or the reason it is absent",
        arguments: [
            (Availability<Data>.available(Data()), true, "On"),
            (.absent(.notImplemented, debugDetail: ""), false, "This agent doesn't offer it."),
            (.absent(.noAgent, debugDetail: ""), false, "No Kernova agent is connected."),
        ])
    func updateRow(status: Availability<Data>, isAvailable: Bool, detail: String) {
        let presentation = GuestAgentPresentation(hub: Self.snapshot([Self.peer(1)], update: status))
        #expect(
            presentation.hub?.capabilities.first { $0.title == "Automatic agent updates" }
                == .init(title: "Automatic agent updates", isAvailable: isAvailable, detail: detail))
    }

    @Test(
        "The logs row reads the merged LOGS status: on, or the reason it is absent",
        arguments: [
            (AbsenceReason.disabledByPolicy, "Turned off in Settings."),
            (.notImplemented, "This agent doesn't offer it."),
            (.versionMismatch, "The agent is out of date."),
            (.protocolMismatch, "The agent is out of date."),
        ])
    func logsRow(reason: AbsenceReason, detail: String) {
        let presentation = GuestAgentPresentation(
            hub: Self.snapshot([Self.peer(1)], logs: .absent(reason, debugDetail: "")))
        #expect(
            presentation.hub?.capabilities.first { $0.title == "Guest logs in Console" }
                == .init(title: "Guest logs in Console", isAvailable: false, detail: detail))
    }

    @Test(
        "An outdated agent that is not updating itself makes the whole presentation outdated, and its line says why",
        arguments: [
            (PeerSummary.InBandUpdate.unavailable, "Out of date; this agent can\u{2019}t update itself"),
            (.failed, "Update failed"),
        ])
    func hubWithAnOutdatedPeer(update: PeerSummary.InBandUpdate, line: String) {
        let presentation = GuestAgentPresentation(
            hub: Self.snapshot([
                Self.peer(
                    3, role: .systemPeer, version: "0.9",
                    standing: .outdated(offeredVersionLabel: "1.0", update: .updating)),
                Self.peer(1, version: "0.9", standing: .outdated(offeredVersionLabel: "1.0", update: update)),
            ]))
        #expect(presentation.status == .outdated(installed: "0.9", bundled: "1.0"))
        #expect(
            presentation.hub?.windowLines == [
                .init(title: "System service", state: "Updating\u{2026}"),
                .init(title: "Session agent — pbear", state: line),
            ])
    }

    @Test("Outdated agents that all update themselves make the presentation updating, ahead of an unresponsive one")
    func hubWithUpdatingPeers() {
        let presentation = GuestAgentPresentation(
            hub: Self.snapshot([
                Self.peer(3, role: .systemPeer, isResponsive: false),
                Self.peer(1, version: "0.9", standing: .outdated(offeredVersionLabel: "1.0", update: .updating)),
            ]))
        #expect(presentation.status == .updating(installed: "0.9", bundled: "1.0"))
        #expect(presentation.hub?.agents.map(\.state) == ["Not responding", "Updating\u{2026}"])
    }

    @Test(
        "An agent the host offers nothing claims no currency: its line names its version, and the status is connected")
    func hubWithAPeerOfferedNothing() {
        let alone = GuestAgentPresentation(hub: Self.snapshot([Self.peer(1, standing: .notOffered)]))
        #expect(alone.status == .connected(version: "1.0"))
        #expect(alone.hub?.windowLines == [.init(title: "Session agent — pbear", state: "Version 1.0")])
        let mixed = GuestAgentPresentation(
            hub: Self.snapshot([
                Self.peer(2, role: .systemPeer, version: "1.1"), Self.peer(1, standing: .notOffered),
            ]))
        #expect(mixed.status == .connected(version: "1.1"))
        let unlabelled = GuestAgentPresentation(hub: Self.snapshot([Self.peer(1, version: "", standing: .notOffered)]))
        #expect(unlabelled.hub?.agents.first?.state == "Connected")
    }

    @Test("Any unresponsive agent makes the presentation unresponsive, and its line says so")
    func hubResponsiveness() {
        let unresponsive = GuestAgentPresentation(
            hub: Self.snapshot([
                Self.peer(2, version: "1.1", isResponsive: false), Self.peer(1, role: .systemPeer, isResponsive: false),
            ]))
        #expect(unresponsive.status == .unresponsive(version: "1.1"))
        let mixed = GuestAgentPresentation(
            hub: Self.snapshot([Self.peer(2, role: .systemPeer), Self.peer(1, version: "0.9", isResponsive: false)]))
        #expect(mixed.status == .unresponsive(version: "0.9"))
        #expect(mixed.hub?.agents.map(\.state) == ["Up to date", "Not responding"])
    }

    // MARK: Away peers

    private static func away(_ peer: PeerSummary, relaunching: Bool = false, order: UInt64 = 1) -> AwayPeer {
        AwayPeer(summary: peer, relaunching: relaunching, order: order, since: SystemScheduler().now)
    }

    @Test("With only away peers the session is connecting to the agent it saw, never waiting for an install")
    func awayIsConnecting() {
        let presentation = GuestAgentPresentation(
            hub: AgentHubSnapshot(
                peers: [], features: FeatureStatus.merge([]), away: [Self.away(Self.peer(1))]),
            lastSeenAgentVersion: "1.0")
        #expect(presentation.status == .connecting(expected: "1.0"))
        #expect(presentation.hub?.windowLines == [.init(title: "Session agent — pbear", state: "Reconnecting\u{2026}")])
    }

    @Test("A VM that has had an agent and has none connected yet — a cold boot — is connecting to it")
    func coldBootIsConnecting() {
        let presentation = GuestAgentPresentation(hub: .empty, lastSeenAgentVersion: "1.0")
        #expect(presentation.status == .connecting(expected: "1.0"))
        #expect(GuestAgentPresentation(hub: .empty).status == .waiting)
    }

    // MARK: Missing agents

    private static let missingSession = AgentScopePresence(
        scope: .login, lastSeenVersion: "0.10.0 (1147)", seenThisSession: false, isConnected: false)
    private static let missingSystem = AgentScopePresence(
        scope: .system, lastSeenVersion: "0.10.0 (1147)", seenThisSession: true, isConnected: false)

    @Test("(a) The session agent missing beside a connected system service gets its own line under the warning")
    func sessionAgentMissing() {
        let presentation = GuestAgentPresentation(
            hub: AgentHubSnapshot(
                peers: [Self.peer(2, role: .systemPeer, version: "0.10.0 (1147)")], features: FeatureStatus.merge([])),
            lastSeenAgentVersion: "0.10.0 (1147)", missing: [Self.missingSession])
        #expect(presentation.status == .expectedMissing(expected: "0.10.0 (1147)"))
        #expect(
            presentation.hub?.windowLines == [
                .init(title: "System service", state: "Up to date"),
                .init(title: "Session agent", state: "Didn\u{2019}t reconnect; it starts when a user logs in"),
            ])
    }

    @Test("(b) The system service missing gets its own line, in place of its away line")
    func systemServiceMissing() {
        let presentation = GuestAgentPresentation(
            hub: AgentHubSnapshot(
                peers: [Self.peer(1, version: "0.10.0 (1147)")], features: FeatureStatus.merge([]),
                away: [
                    AwayPeer(
                        summary: Self.peer(2, role: .systemPeer), relaunching: false, order: 3,
                        since: SystemScheduler().now)
                ]),
            lastSeenAgentVersion: "0.10.0 (1147)", missing: [Self.missingSystem])
        #expect(presentation.status == .expectedMissing(expected: "0.10.0 (1147)"))
        #expect(
            presentation.hub?.windowLines == [
                .init(title: "Session agent — pbear", state: "Up to date"),
                .init(title: "System service", state: "Didn\u{2019}t reconnect"),
            ])
    }

    @Test("(c) Both missing: a line for each, and no connected agent")
    func bothMissing() {
        let presentation = GuestAgentPresentation(
            hub: .empty, lastSeenAgentVersion: "0.10.0 (1147)", missing: [Self.missingSession, Self.missingSystem])
        #expect(presentation.status == .expectedMissing(expected: "0.10.0 (1147)"))
        #expect(
            presentation.hub?.windowLines == [
                .init(title: "Session agent", state: "Didn\u{2019}t reconnect; it starts when a user logs in"),
                .init(title: "System service", state: "Didn\u{2019}t reconnect"),
            ])
    }

    @Test("(d) The macOS agent's presentation is unchanged: its status alone, no agent lines")
    func macOSMissingUnchanged() {
        let presentation = GuestAgentPresentation(macOSAgent: .expectedMissing(expected: "0.9.2"))
        #expect(presentation.status == .expectedMissing(expected: "0.9.2"))
        #expect(presentation.hub == nil)
    }

    @Test("A peer relaunching into an update keeps reading Updating…, and the status stays updating")
    func relaunchingKeepsUpdating() {
        let updating = Self.peer(
            1, version: "0.9", standing: .outdated(offeredVersionLabel: "1.0", update: .updating))
        let alone = GuestAgentPresentation(
            hub: AgentHubSnapshot(
                peers: [], features: FeatureStatus.merge([]), away: [Self.away(updating, relaunching: true)]),
            lastSeenAgentVersion: "0.9")
        #expect(alone.status == .updating(installed: "0.9", bundled: "1.0"))
        #expect(alone.hub?.agents.map(\.state) == ["Updating\u{2026}"])
        // Beside a peer already current again, the relaunching one still decides the status.
        let mixed = GuestAgentPresentation(
            hub: AgentHubSnapshot(
                peers: [Self.peer(2, role: .systemPeer, version: "1.0")], features: FeatureStatus.merge([]),
                away: [Self.away(updating, relaunching: true)]), lastSeenAgentVersion: "1.0")
        #expect(mixed.status == .updating(installed: "0.9", bundled: "1.0"))
        #expect(mixed.hub?.agents.map(\.state) == ["Up to date", "Updating\u{2026}"])
    }

    @Test("An away peer beside a connected one leaves the status to the connected one")
    func awayBesideConnected() {
        let presentation = GuestAgentPresentation(
            hub: AgentHubSnapshot(
                peers: [Self.peer(2, role: .systemPeer)], features: FeatureStatus.merge([]),
                away: [Self.away(Self.peer(1))]), lastSeenAgentVersion: "1.0")
        #expect(presentation.status == .current(version: "1.0"))
        #expect(presentation.hub?.agents.map(\.state) == ["Up to date", "Reconnecting\u{2026}"])
    }

    @Test("A session agent with no user name is named by its role")
    func sessionPeerWithoutUserName() {
        let presentation = GuestAgentPresentation(hub: Self.snapshot([Self.peer(1, userName: "")]))
        #expect(presentation.hub?.agents.first?.title == "Session agent")
    }

    @Test("Each absence reason reads as what it means")
    func reasonCopy() {
        #expect(GuestAgentPresentation.reason(.noAgent) == "No Kernova agent is connected.")
        #expect(GuestAgentPresentation.reason(.disabledByPolicy) == "Turned off in Settings.")
        #expect(GuestAgentPresentation.reason(.versionMismatch) == "The agent is out of date.")
        #expect(GuestAgentPresentation.reason(.protocolMismatch) == "The agent is out of date.")
        #expect(GuestAgentPresentation.reason(.notImplemented) == "This agent doesn't offer it.")
    }
}

/// What the Guest Agent Status window shows of one agent line.
struct WindowLine: Equatable {
    var title: String
    var state: String
}

extension GuestAgentPresentation.Hub {
    /// Each agent line as the window shows it.
    var windowLines: [WindowLine] { agents.map { WindowLine(title: $0.title, state: $0.state) } }
}
