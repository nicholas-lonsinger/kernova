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
        _ peers: [PeerSummary], logs: Availability<Data>? = nil, update: Availability<Data>? = nil,
        inBandUpdatesWithheld: Bool = false
    ) -> AgentHubSnapshot {
        let rows = [logs.map { (feature: FeatureID.logs, status: $0) }, update.map { (feature: .update, status: $0) }]
        let features =
            logs == nil && update == nil ? FeatureStatus.merge([]) : FeatureStatusTable(rows.compactMap { $0 })
        return AgentHubSnapshot(peers: peers, features: features, inBandUpdatesWithheld: inBandUpdatesWithheld)
    }

    @Test("With no agent connected, the hub's presentation is waiting, and its Status and logs rows say why")
    func hubWithNoPeers() {
        let presentation = GuestAgentPresentation(hub: .empty)
        #expect(presentation.status == .waiting)
        #expect(presentation.windowLines == [])
        #expect(
            presentation.capabilities == [
                .init(title: "Status", isAvailable: false, detail: "No Kernova agent is connected."),
                .init(title: "Guest logs in Console", isAvailable: false, detail: "No Kernova agent is connected."),
                .init(title: "Automatic agent updates", isAvailable: false, detail: "No Kernova agent is connected."),
                .init(title: "Stop and Restart", isAvailable: false, detail: "No Kernova agent is connected."),
                .init(
                    title: "Stop Anyway and Restart Anyway", isAvailable: false,
                    detail: "No system service is connected."),
            ])
    }

    @Test("One current session agent is a line naming its user, and the Status row is connected")
    func hubWithOneCurrentPeer() {
        let presentation = GuestAgentPresentation(hub: Self.snapshot([Self.peer(1)], logs: .available(Data())))
        #expect(presentation.status == .current(version: "1.0"))
        #expect(presentation.windowLines == [.init(title: "Session agent — pbear", state: "Up to date")])
        #expect(
            presentation.capabilities == [
                .init(title: "Status", isAvailable: true, detail: "Connected"),
                .init(title: "Guest logs in Console", isAvailable: true, detail: "On"),
                .init(title: "Automatic agent updates", isAvailable: false, detail: "This agent doesn't offer it."),
                .init(title: "Stop and Restart", isAvailable: false, detail: "No Kernova agent is connected."),
                .init(
                    title: "Stop Anyway and Restart Anyway", isAvailable: false,
                    detail: "No system service is connected."),
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
            presentation.capabilities.first { $0.title == "Automatic agent updates" }
                == .init(title: "Automatic agent updates", isAvailable: isAvailable, detail: detail))
    }

    @Test(
        "Where the host withholds in-band updates, the automatic updates row is unavailable and names what enables it, outdated or current; otherwise it reads UPDATE",
        arguments: [
            (
                PeerSummary.Standing.outdated(offeredVersionLabel: "1.1", update: .notTeamSigned), true, false,
                "Needs a team-signed build of Kernova"
            ),
            (.current, true, false, "Needs a team-signed build of Kernova"),
            (.current, false, true, "On"),
            (.outdated(offeredVersionLabel: "1.1", update: .updating), false, true, "On"),
        ])
    func updateRowWhereTheHostWithholdsUpdates(
        standing: PeerSummary.Standing, withheld: Bool, isAvailable: Bool, detail: String
    ) {
        let presentation = GuestAgentPresentation(
            hub: Self.snapshot(
                [Self.peer(1, standing: standing)], update: .available(Data()), inBandUpdatesWithheld: withheld))
        #expect(
            presentation.capabilities.first { $0.title == "Automatic agent updates" }
                == .init(title: "Automatic agent updates", isAvailable: isAvailable, detail: detail))
    }

    @Test("With no agent connected, the automatic updates row says so whatever the bundles")
    func updateRowWithNoAgent() {
        let presentation = GuestAgentPresentation(hub: .empty)
        #expect(!AgentHubSnapshot.empty.inBandUpdatesWithheld)
        #expect(
            presentation.capabilities.first { $0.title == "Automatic agent updates" }
                == .init(title: "Automatic agent updates", isAvailable: false, detail: "No Kernova agent is connected.")
        )
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
            presentation.capabilities.first { $0.title == "Guest logs in Console" }
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
            presentation.windowLines == [
                .init(title: "System service", state: "Updating\u{2026}"),
                .init(title: "Session agent — pbear", state: line),
            ])
    }

    @Test(
        "An agent that can't take the update in place makes the presentation reinstall-needed for its reason, ahead of another outdated one",
        arguments: [
            (PeerSummary.InBandUpdate.launchRefused, AgentStatus.ReinstallReason.launchRefused),
            (.notTeamSigned, .notTeamSigned),
        ])
    func hubWithAPeerThatCantUpdateInPlace(update: PeerSummary.InBandUpdate, reason: AgentStatus.ReinstallReason) {
        let presentation = GuestAgentPresentation(
            hub: Self.snapshot([
                Self.peer(1, version: "0.9", standing: .outdated(offeredVersionLabel: "1.0", update: .unavailable)),
                Self.peer(
                    3, role: .systemPeer, version: "0.8",
                    standing: .outdated(offeredVersionLabel: "1.0", update: update)),
            ]))
        #expect(presentation.status == .reinstallNeeded(installed: "0.8", bundled: "1.0", reason: reason))
        #expect(presentation.status.wireName == "reinstallNeeded")
        #expect(
            presentation.windowLines == [
                .init(title: "Session agent — pbear", state: "Out of date; this agent can\u{2019}t update itself"),
                .init(title: "System service", state: "Can\u{2019}t update in place"),
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
        #expect(presentation.agents.map(\.state) == ["Not responding", "Updating\u{2026}"])
    }

    @Test(
        "An agent the host bundles nothing for claims no currency: its line names its version, and the status is connected"
    )
    func hubWithAPeerBundledNothing() {
        let alone = GuestAgentPresentation(hub: Self.snapshot([Self.peer(1, standing: .notOffered)]))
        #expect(alone.status == .connected(version: "1.0"))
        #expect(alone.windowLines == [.init(title: "Session agent — pbear", state: "Version 1.0")])
        let mixed = GuestAgentPresentation(
            hub: Self.snapshot([
                Self.peer(2, role: .systemPeer, version: "1.1"), Self.peer(1, standing: .notOffered),
            ]))
        #expect(mixed.status == .connected(version: "1.1"))
        let unlabelled = GuestAgentPresentation(hub: Self.snapshot([Self.peer(1, version: "", standing: .notOffered)]))
        #expect(unlabelled.agents.first?.state == "Connected")
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
        #expect(mixed.agents.map(\.state) == ["Up to date", "Not responding"])
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
        #expect(presentation.windowLines == [.init(title: "Session agent — pbear", state: "Reconnecting\u{2026}")])
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
            presentation.windowLines == [
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
            presentation.windowLines == [
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
            presentation.windowLines == [
                .init(title: "Session agent", state: "Didn\u{2019}t reconnect; it starts when a user logs in"),
                .init(title: "System service", state: "Didn\u{2019}t reconnect"),
            ])
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
        #expect(alone.agents.map(\.state) == ["Updating\u{2026}"])
        // Beside a peer already current again, the relaunching one still decides the status.
        let mixed = GuestAgentPresentation(
            hub: AgentHubSnapshot(
                peers: [Self.peer(2, role: .systemPeer, version: "1.0")], features: FeatureStatus.merge([]),
                away: [Self.away(updating, relaunching: true)]), lastSeenAgentVersion: "1.0")
        #expect(mixed.status == .updating(installed: "0.9", bundled: "1.0"))
        #expect(mixed.agents.map(\.state) == ["Up to date", "Updating\u{2026}"])
    }

    @Test("An away peer beside a connected one leaves the status to the connected one")
    func awayBesideConnected() {
        let presentation = GuestAgentPresentation(
            hub: AgentHubSnapshot(
                peers: [Self.peer(2, role: .systemPeer)], features: FeatureStatus.merge([]),
                away: [Self.away(Self.peer(1))]), lastSeenAgentVersion: "1.0")
        #expect(presentation.status == .current(version: "1.0"))
        #expect(presentation.agents.map(\.state) == ["Up to date", "Reconnecting\u{2026}"])
    }

    @Test("A session agent with no user name is named by its role")
    func sessionPeerWithoutUserName() {
        let presentation = GuestAgentPresentation(hub: Self.snapshot([Self.peer(1, userName: "")]))
        #expect(presentation.agents.first?.title == "Session agent")
    }

    private static let powerTitles = ["Stop and Restart", "Stop Anyway and Restart Anyway"]

    /// The Stop and Restart row, then the Stop Anyway and Restart Anyway row,
    /// of a snapshot whose provisions are `power` and `ignoringApps`.
    private static func powerRows(
        _ power: PowerProvision, ignoringApps: PowerProvision, routing: PowerRoutingProgress? = nil
    ) -> [GuestAgentPresentation.CapabilityRow] {
        let snapshot = AgentHubSnapshot(
            peers: [Self.peer(1)], features: FeatureStatus.merge([]), power: power, powerIgnoringApps: ignoringApps,
            routing: routing)
        return GuestAgentPresentation(hub: snapshot).capabilities.filter { powerTitles.contains($0.title) }
    }

    @Test(
        "Each power row names the agent its provision would ask",
        arguments: [(PeerRole.sessionPeer, "Through the session agent"), (.systemPeer, "Through the system service")])
    func powerRowsAgent(role: PeerRole, detail: String) {
        #expect(
            Self.powerRows(.agent(role), ignoringApps: .agent(role))
                == Self.powerTitles.map { .init(title: $0, isAvailable: true, detail: detail) })
    }

    @Test(
        "Each power row says why no agent would take its shutdown, naming the system service for the one ignoring apps",
        arguments: [
            (
                AbsenceReason.notOnConsole, "Available to the session at the guest\u{2019}s screen.",
                "Available to the session at the guest\u{2019}s screen."
            ),
            (.noAgent, "No Kernova agent is connected.", "No system service is connected."),
            (.disabledByPolicy, "Turned off in Settings.", "Turned off in Settings."),
            (.versionMismatch, "The agent is out of date.", "The agent is out of date."),
            (.notImplemented, "This agent doesn't offer it.", "This agent doesn't offer it."),
            (.unspecified, "Unavailable.", "Unavailable."),
        ])
    func powerRowsAbsent(reason: AbsenceReason, stop: String, anyway: String) {
        #expect(
            Self.powerRows(.absent(reason), ignoringApps: .absent(reason)) == [
                .init(title: "Stop and Restart", isAvailable: false, detail: stop),
                .init(title: "Stop Anyway and Restart Anyway", isAvailable: false, detail: anyway),
            ])
    }

    /// Each stage a routing reaches, and how its row reads it.
    static let stages: [(PowerRoutingProgress.Stage, String)] = [
        (.asking, "Shutting down\u{2026}"),
        (.accepted, "Shutting down\u{2026}"),
        (.askingApps, "Asking apps to quit\u{2026}"),
        (.waitingOnApps([AppValue(displayName: "Text Editor")]), "Waiting on Text Editor"),
        (
            .waitingOnApps([AppValue(displayName: "Text Editor"), AppValue(displayName: "Terminal")]),
            "Waiting on Text Editor and Terminal"
        ),
    ]

    @Test(
        "While a shutdown is routed, its own row shows its stage whatever its provision, and the other row its provision",
        arguments: stages, [false, true])
    func powerRowsRouting(stage: (PowerRoutingProgress.Stage, String), ignoringApps: Bool) {
        let routing = PowerRoutingProgress(
            action: .shutdown, ignoringApps: ignoringApps, role: ignoringApps ? .systemPeer : .sessionPeer,
            stage: stage.0)
        let rows = Self.powerRows(.absent(.notOnConsole), ignoringApps: .absent(.noAgent), routing: routing)
        let running = GuestAgentPresentation.CapabilityRow(
            title: Self.powerTitles[ignoringApps ? 1 : 0], isAvailable: true, detail: stage.1)
        let idle =
            ignoringApps
            ? GuestAgentPresentation.CapabilityRow(
                title: "Stop and Restart", isAvailable: false,
                detail: "Available to the session at the guest\u{2019}s screen.")
            : GuestAgentPresentation.CapabilityRow(
                title: "Stop Anyway and Restart Anyway", isAvailable: false, detail: "No system service is connected.")
        #expect(rows == (ignoringApps ? [idle, running] : [running, idle]))
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

extension GuestAgentPresentation {
    /// Each agent line as the window shows it.
    var windowLines: [WindowLine] { agents.map { WindowLine(title: $0.title, state: $0.state) } }
}
