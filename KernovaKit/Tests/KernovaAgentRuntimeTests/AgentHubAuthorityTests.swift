#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
@testable import KernovaAgentCore
@testable import KernovaAgentHost
import KernovaAgentRuntime
import KernovaAgentSimulation
import KernovaWire
import Testing

/// Console authority over the hub's items, and the end of a connection's item calls, against connections the
/// test scripts event by event.
@Suite("Agent hub item authority")
struct AgentHubAuthorityTests {
    static let features = FeatureStatusTable(
        ItemFeatureAvailability.offering.map { ($0, Availability<Data>.available(Data())) })

    /// A hub over scripted connections, its item events recorded.
    private final class ScriptedHub: Sendable {
        let connector = ScriptedConnector()
        let transport = TestTransport()
        let items = Recorder<HubItemEvent>()
        let hub: AgentHub

        init() async throws {
            let items = items
            hub = AgentHub(
                connector: connector, policy: PolicySnapshot(), payloads: FixedPayloads(bundles: []),
                logger: Fixture.logger, itemEvents: { items.record($0) },
                publishingOn: DispatchQueue(label: "app.kernova.tests.authority-publish")
            ) { _ in }
            hub.attach(transport, policy: PolicySnapshot(), republisher: GuestLogRepublisher(vmLabel: "t"))
            try await flush(hub.queue)
        }
    }

    /// The console peer of each feature that offers items becoming `peer`, in feature order.
    private static func console(_ peer: PeerHandle?) -> [HubItemEvent] {
        [FeatureID.clipboard, .drop, .drag].map { .consolePeer($0, peer) }
    }

    private static func header(_ tag: UInt8, _ feature: FeatureID) -> ItemSetHeaderValue {
        ItemSetHeaderValue(feature: feature, token: SimItems.token(tag), concealed: false, count: 1)
    }

    @Test("A connection that never said Hello, or one displaced, hands the owner none of its item events")
    func strangersAreNotHeard() async throws {
        let scripted = try await ScriptedHub()
        let connector = scripted.connector
        _ = scripted.transport.connect()
        _ = scripted.transport.connect()
        let (stranger, first) = (0, 1)
        let firstHandle = PeerHandle(rawValue: 2)
        connector.deliver(.role(.helloReceived(Fixture.peerClaim, Fixture.peerState)), first)
        connector.deliver(.role(.featuresChanged(Self.features)), first)
        connector.deliver(.items(.offerReceived(Self.header(1, .clipboard))), stranger)
        connector.deliver(.items(.offerEnded(.clipboard, .local, token: SimItems.token(2), .connectionLost)), stranger)
        let pull = ItemPullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: 3))
        connector.deliver(.items(.pullEnded(.clipboard, pull, .landed(.named(Data())))), stranger)
        let take = DragTakeID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: 5))
        connector.deliver(.dragTake(.ended(take, .caught(nil))), stranger)
        connector.deliver(.items(.offerReceived(Self.header(3, .clipboard))), first)
        try await flush(scripted.hub.queue)
        #expect(
            scripted.items.elements
                == Self.console(firstHandle) + [.items(firstHandle, .offerReceived(Self.header(3, .clipboard)))])

        // The same claim again supersedes the first connection: what the owner held there ends at once.
        _ = scripted.transport.connect()
        connector.deliver(.role(.helloReceived(Fixture.peerClaim, Fixture.peerState)), 2)
        connector.deliver(.role(.featuresChanged(Self.features)), 2)
        connector.deliver(
            .items(.offerEnded(.clipboard, .remote, token: SimItems.token(3), .connectionLost)), first)
        connector.deliver(.items(.offerReceived(Self.header(4, .drag))), first)
        try await flush(scripted.hub.queue)
        #expect(
            scripted.items.elements
                == Self.console(firstHandle) + [
                    .items(firstHandle, .offerReceived(Self.header(3, .clipboard))),
                    // No peer is CLIPBOARD's console peer until the new connection's features arrive.
                    .items(
                        firstHandle,
                        .offerEnded(
                            .clipboard, .remote, token: SimItems.token(3),
                            .resetLocally(WireError(.featureUnavailable, absence: .noAgent)))),
                ]
                // The new connection's features arrive after its Hello displaced the first.
                + Self.console(nil) + Self.console(PeerHandle(rawValue: 3)))
        #expect(connector.commands(to: stranger) == [.items(.release(token: SimItems.token(1)))])
        #expect(
            connector.commands(to: first) == [
                .close(.superseded, retryAfter: nil), .items(.release(token: SimItems.token(3))),
                .items(.release(token: SimItems.token(4))),
            ])
        scripted.hub.close()
    }

    @Test("A pending call ends SHUTTING_DOWN on its connection's .closed, exactly once; a late answer is dropped")
    func pendingCallEndsOnClose() async throws {
        let scripted = try await ScriptedHub()
        let connector = scripted.connector
        _ = scripted.transport.connect()
        connector.deliver(.role(.helloReceived(Fixture.peerClaim, Fixture.peerState)), 0)
        connector.deliver(.role(.featuresChanged(Self.features)), 0)
        try await flush(scripted.hub.queue)
        let answers = Recorder<Result<PeerHandle, WireError>>()
        scripted.hub.offerItems(SimItems.offer(1, []), feature: .clipboard) { answers.record($0) }
        var commands = connector.commands.waiter()
        let sent = try await commands.next { if case .items(.offer) = $0.command { true } else { false } }
        guard case .items(.offer(let id, _, _)) = sent.command else { Issue.record("sent \(sent)"); return }

        connector.deliver(.closed(.transportLost), 0)
        connector.deliver(.itemReply(id, .offered(nil)), 0)
        try await flush(scripted.hub.queue)
        guard case .failure(let error) = answers.elements.first, answers.elements.count == 1 else {
            Issue.record("answered \(answers.elements)"); return
        }
        #expect(error.code == .shuttingDown)
        #expect(scripted.items.elements == Self.console(PeerHandle(rawValue: 1)) + Self.console(nil))
        scripted.hub.close()
    }
}
