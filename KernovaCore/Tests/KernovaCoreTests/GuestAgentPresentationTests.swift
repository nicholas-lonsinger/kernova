import Foundation
import KernovaAgentCore
import KernovaAgentHost
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
