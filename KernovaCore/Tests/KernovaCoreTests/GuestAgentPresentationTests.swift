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
        isCurrent: Bool = true, offered: String? = nil, isResponsive: Bool = true
    ) -> PeerSummary {
        PeerSummary(
            handle: PeerHandle(rawValue: handle), role: role, scope: role == .systemPeer ? .system : .user,
            os: .linux, sessionID: role == .systemPeer ? "" : "2", userName: role == .systemPeer ? "" : userName,
            console: .on, versionLabel: version, isCurrent: isCurrent, offeredVersionLabel: offered,
            isResponsive: isResponsive)
    }

    private static func snapshot(_ peers: [PeerSummary]) -> AgentHubSnapshot {
        AgentHubSnapshot(peers: peers, features: FeatureStatus.merge([]))
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

    @Test("With no agent connected, the hub's presentation is waiting, and its Status row says why")
    func hubWithNoPeers() {
        let presentation = GuestAgentPresentation(hub: .empty)
        #expect(presentation.status == .waiting)
        #expect(presentation.hub?.peers == [])
        #expect(
            presentation.hub?.capabilities == [
                .init(title: "Status", isAvailable: false, detail: "No Kernova agent is connected.")
            ])
    }

    @Test("One current session agent is a line naming its user, and the Status row is connected")
    func hubWithOneCurrentPeer() {
        let presentation = GuestAgentPresentation(hub: Self.snapshot([Self.peer(1)]))
        #expect(presentation.status == .current(version: "1.0"))
        #expect(presentation.hub?.peers == [.init(title: "Session agent — pbear", state: "Up to date")])
        #expect(presentation.hub?.capabilities == [.init(title: "Status", isAvailable: true, detail: "Connected")])
    }

    @Test("An outdated agent makes the whole presentation outdated, and each agent keeps its own line")
    func hubWithAnOutdatedPeer() {
        let presentation = GuestAgentPresentation(
            hub: Self.snapshot([
                Self.peer(2, role: .systemPeer, version: "1.0"),
                Self.peer(1, version: "0.9", isCurrent: false, offered: "1.0"),
            ]))
        #expect(presentation.status == .outdated(installed: "0.9", bundled: "1.0"))
        #expect(
            presentation.hub?.peers == [
                .init(title: "System service", state: "Up to date"),
                .init(title: "Session agent — pbear", state: "Out of date"),
            ])
    }

    @Test("Agents all unresponsive read as unresponsive; one responsive agent keeps the presentation current")
    func hubResponsiveness() {
        let unresponsive = GuestAgentPresentation(
            hub: Self.snapshot([
                Self.peer(2, version: "1.1", isResponsive: false), Self.peer(1, role: .systemPeer, isResponsive: false),
            ]))
        #expect(unresponsive.status == .unresponsive(version: "1.1"))
        let mixed = GuestAgentPresentation(
            hub: Self.snapshot([Self.peer(2, version: "1.1", isResponsive: false), Self.peer(1, role: .systemPeer)]))
        #expect(mixed.status == .current(version: "1.1"))
    }

    @Test("A session agent with no user name is named by its role")
    func sessionPeerWithoutUserName() {
        let presentation = GuestAgentPresentation(hub: Self.snapshot([Self.peer(1, userName: "")]))
        #expect(presentation.hub?.peers.first?.title == "Session agent")
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
