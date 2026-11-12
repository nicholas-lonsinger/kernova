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

    /// `scope` as the session reads it, its agent last seen at `version`: by default connected earlier this
    /// session and gone now.
    private static func presence(
        _ scope: GuestAgentScope, _ version: String = "1.0", seen: Bool = true, connected: Bool = false
    ) -> AgentScopePresence {
        AgentScopePresence(scope: scope, lastSeenVersion: version, seenThisSession: seen, isConnected: connected)
    }

    // MARK: Disconnected agents

    @Test("While another scope is still awaited, a departed one leaves the status connecting")
    func departedWhileAwaited() {
        let presentation = GuestAgentPresentation(
            hub: .empty, presences: [Self.presence(.login, "0.9"), Self.presence(.system, "1.0", seen: false)])
        #expect(presentation.status == .connecting(expected: "1.0"))
        #expect(presentation.windowLines == [.init(title: "Session agent", state: "Disconnected")])
    }

    // MARK: Missing agents

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
