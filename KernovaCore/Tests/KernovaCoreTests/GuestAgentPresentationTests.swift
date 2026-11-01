import Foundation
import KernovaAgentCore
import KernovaAgentHost
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
        #expect(presentation.hub?.peers == [])
        #expect(
            presentation.hub?.capabilities == [
                .init(title: "Status", isAvailable: false, detail: "No Kernova agent is connected."),
                .init(title: "Guest logs in Console", isAvailable: false, detail: "No Kernova agent is connected."),
                .init(
                    title: "Shut down and restart from Kernova", isAvailable: false,
                    detail: "No Kernova agent is connected."),
                .init(title: "Automatic agent updates", isAvailable: false, detail: "No Kernova agent is connected."),
            ])
    }

    @Test("One current session agent is a line naming its user, and the Status row is connected")
    func hubWithOneCurrentPeer() {
        let presentation = GuestAgentPresentation(hub: Self.snapshot([Self.peer(1)], logs: .available(Data())))
        #expect(presentation.status == .current(version: "1.0"))
        #expect(presentation.hub?.peers == [.init(title: "Session agent — pbear", state: "Up to date")])
        #expect(
            presentation.hub?.capabilities == [
                .init(title: "Status", isAvailable: true, detail: "Connected"),
                .init(title: "Guest logs in Console", isAvailable: true, detail: "On"),
                .init(
                    title: "Shut down and restart from Kernova", isAvailable: false,
                    detail: "No Kernova agent is connected."),
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
            presentation.hub?.peers == [
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
        #expect(presentation.hub?.peers.map(\.state) == ["Not responding", "Updating\u{2026}"])
    }

    @Test(
        "An agent the host offers nothing claims no currency: its line names its version, and the status is connected")
    func hubWithAPeerOfferedNothing() {
        let alone = GuestAgentPresentation(hub: Self.snapshot([Self.peer(1, standing: .notOffered)]))
        #expect(alone.status == .connected(version: "1.0"))
        #expect(alone.hub?.peers == [.init(title: "Session agent — pbear", state: "Version 1.0")])
        let mixed = GuestAgentPresentation(
            hub: Self.snapshot([
                Self.peer(2, role: .systemPeer, version: "1.1"), Self.peer(1, standing: .notOffered),
            ]))
        #expect(mixed.status == .connected(version: "1.1"))
        let unlabelled = GuestAgentPresentation(hub: Self.snapshot([Self.peer(1, version: "", standing: .notOffered)]))
        #expect(unlabelled.hub?.peers.first?.state == "Connected")
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
        #expect(mixed.hub?.peers.map(\.state) == ["Up to date", "Not responding"])
    }

    @Test("A session agent with no user name is named by its role")
    func sessionPeerWithoutUserName() {
        let presentation = GuestAgentPresentation(hub: Self.snapshot([Self.peer(1, userName: "")]))
        #expect(presentation.hub?.peers.first?.title == "Session agent")
    }

    private static func powerRow(
        _ power: PowerProvision, routing: PowerRoutingProgress? = nil
    ) -> GuestAgentPresentation.CapabilityRow? {
        let snapshot = AgentHubSnapshot(
            peers: [Self.peer(1)], features: FeatureStatus.merge([]), power: power, routing: routing)
        return GuestAgentPresentation(hub: snapshot).hub?.capabilities.first {
            $0.title == "Shut down and restart from Kernova"
        }
    }

    @Test(
        "The shutdown row names the agent a Stop or Restart would ask",
        arguments: [(PeerRole.sessionPeer, "Through the session agent"), (.systemPeer, "Through the system service")])
    func powerRowAgent(role: PeerRole, detail: String) {
        #expect(
            Self.powerRow(.agent(role))
                == .init(title: "Shut down and restart from Kernova", isAvailable: true, detail: detail))
    }

    @Test(
        "The shutdown row says why no agent would take a shutdown",
        arguments: [
            (
                AbsenceReason.notOnConsole,
                "Available while someone is logged in at the guest\u{2019}s screen, or with the system service installed."
            ),
            (.notPermitted, "The guest doesn\u{2019}t permit its agents to shut it down."),
            (.missingOsComponent, "This guest has no polkit."),
            (.noAgent, "No Kernova agent is connected."),
            (.disabledByPolicy, "Turned off in Settings."),
            (.versionMismatch, "The agent is out of date."),
            (.notImplemented, "This agent doesn't offer it."),
        ])
    func powerRowAbsent(reason: AbsenceReason, detail: String) {
        #expect(
            Self.powerRow(.absent(reason))
                == .init(title: "Shut down and restart from Kernova", isAvailable: false, detail: detail))
    }

    @Test(
        "While a shutdown is routed, the shutdown row shows its stage, whatever agent the next one would ask",
        arguments: [
            (PowerRoutingProgress.Stage.asking, "Shutting down\u{2026}"),
            (.accepted, "Shutting down\u{2026}"),
            (.askingApps, "Asking apps to quit\u{2026}"),
            (.waitingOnApps([AppValue(displayName: "Text Editor")]), "Waiting on Text Editor"),
            (
                .waitingOnApps([AppValue(displayName: "Text Editor"), AppValue(displayName: "Terminal")]),
                "Waiting on Text Editor and Terminal"
            ),
        ])
    func powerRowRouting(stage: PowerRoutingProgress.Stage, detail: String) {
        let routing = PowerRoutingProgress(action: .shutdown, role: .sessionPeer, stage: stage)
        #expect(
            Self.powerRow(.absent(.notOnConsole), routing: routing)
                == .init(title: "Shut down and restart from Kernova", isAvailable: true, detail: detail))
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
