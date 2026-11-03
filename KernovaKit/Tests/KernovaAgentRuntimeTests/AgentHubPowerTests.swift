#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaAgentHost
import KernovaAgentRuntime
import KernovaSynchronization
import KernovaWire
import Testing

/// The hub's power routing against real peer runtimes, over in-memory streams, on the platform clock.
@Suite("Agent hub power routing")
struct AgentHubPowerTests {
    static let systemClaim = PeerClaim(role: .systemPeer, scope: .system, os: .linux, architecture: .arm64)
    static let blocking = [AppValue(displayName: "Text Editor", identifier: "org.gnome.TextEditor")]

    /// A started runtime with `power`, and the snapshot that shows it.
    private func connect(
        _ harness: HubHarness, _ power: FakePowerAdapter, claim: PeerClaim = Fixture.peerClaim,
        state: PeerSessionState = Fixture.peerState, peers: Int = 1
    ) async -> PeerAgentRuntime {
        let runtime = harness.runtime(claim: claim, state: state, registry: PeerFeatureRegistry(power: power))
        runtime.start()
        _ = await harness.snapshot { $0.peers.count == peers && $0.peers.allSatisfy(\.isResponsive) }
        return runtime
    }

    private func close(_ runtimes: [PeerAgentRuntime], _ harness: HubHarness) async {
        for runtime in runtimes {
            await withCheckedContinuation { continuation in runtime.close { continuation.resume() } }
        }
        harness.hub.close()
    }

    @Test("With no agent, routing hands the ACPI press back and asks no one")
    func noAgentUsesACPI() async {
        let harness = HubHarness()
        await harness.attached()
        #expect(await harness.hub.requestPower(.shutdown) == .useACPI(refusals: []))
        #expect(harness.connector.commands.elements.isEmpty)
        harness.hub.close()
    }

    @Test("The console session's peer takes the shutdown, and the merged entry names it")
    func sessionPeerHandsOff() async {
        let harness = HubHarness()
        await harness.attached()
        let power = FakePowerAdapter()
        let session = await connect(harness, power)
        let ready = await harness.snapshot { $0.power == .agent(.sessionPeer) }
        #expect(ready.routing == nil)

        #expect(await harness.hub.requestPower(.shutdown) == .handedOff)
        #expect(power.performed.elements.count == 1)
        #expect(harness.hostLogs.elements.contains { $0.contains("Asking the session peer (session 1") })
        await close([session], harness)
    }

    @Test("A session peer's refusal moves on to the system peer")
    func refusalFallsThrough() async {
        let harness = HubHarness()
        await harness.attached()
        let sessionPower = FakePowerAdapter(accepts: false)
        let systemPower = FakePowerAdapter()
        let session = await connect(harness, sessionPower)
        let system = await connect(
            harness, systemPower, claim: Self.systemClaim,
            state: PeerSessionState(console: .on, consoleSessionID: "1"), peers: 2)
        _ = await harness.snapshot { $0.power == .agent(.sessionPeer) }

        async let outcome = harness.hub.requestPower(.shutdown)
        var performed = sessionPower.performed.waiter()
        let id = await performed.next { _ in true }
        sessionPower.report(.refused(id, WireError(.powerNotPermitted)))

        #expect(await outcome == .handedOff)
        #expect(systemPower.performed.elements.count == 1)
        await close([session, system], harness)
    }

    @Test("Every refusal ends in the ACPI press, carrying the refusals")
    func everyRefusalUsesACPI() async {
        let harness = HubHarness()
        await harness.attached()
        let power = FakePowerAdapter(accepts: false)
        let session = await connect(harness, power)

        async let outcome = harness.hub.requestPower(.shutdown)
        var performed = power.performed.waiter()
        let id = await performed.next { _ in true }
        power.report(.refused(id, WireError(.powerNotPermitted)))

        guard case .useACPI(let refusals) = await outcome else {
            Issue.record("not the ACPI press")
            return
        }
        #expect(refusals.map(\.error.code) == [.powerNotPermitted])
        await close([session], harness)
    }

    @Test("Apps blocking an accepted shutdown end the routing, and the snapshot shows it while it runs")
    func blockedEndsRouting() async {
        let harness = HubHarness()
        await harness.attached()
        let power = FakePowerAdapter(handsOff: false)
        let session = await connect(harness, power)
        _ = await harness.snapshot { $0.power == .agent(.sessionPeer) }

        async let outcome = harness.hub.requestPower(.shutdown)
        let accepted = await harness.snapshot { $0.routing?.stage == .accepted }
        #expect(accepted.routing == PowerRoutingProgress(action: .shutdown, role: .sessionPeer, stage: .accepted))
        // A second request while the first runs is refused at once.
        #expect(await harness.hub.requestPower(.shutdown) == .busy)

        var performed = power.performed.waiter()
        let id = await performed.next { _ in true }
        power.report(.waitingOnApps(id, Self.blocking))
        _ = await harness.snapshot { $0.routing?.stage == .waitingOnApps(Self.blocking) }
        power.report(.blocked(id, Self.blocking))

        #expect(await outcome == .blocked(Self.blocking))
        _ = await harness.snapshot { $0.routing == nil }
        await close([session], harness)
    }

    @Test("A detach after acceptance ends the routing as lost after acceptance")
    func detachAfterAcceptance() async {
        let harness = HubHarness()
        await harness.attached()
        let power = FakePowerAdapter(handsOff: false)
        let session = await connect(harness, power)

        async let outcome = harness.hub.requestPower(.shutdown)
        _ = await harness.snapshot { $0.routing?.stage == .accepted }
        harness.hub.detach()

        #expect(await outcome == .lostAfterAcceptance)
        await close([session], harness)
    }

    @Test("A system peer that says the console is off keeps the session peer out of the merged entry")
    func systemConsoleAuthority() async {
        let harness = HubHarness()
        await harness.attached()
        let session = await connect(harness, FakePowerAdapter())
        let system = await connect(
            harness, FakePowerAdapter(initial: .absent(.notPermitted, debugDetail: "")), claim: Self.systemClaim,
            state: PeerSessionState(console: .off), peers: 2)

        let snapshot = await harness.snapshot { $0.peers.count == 2 && $0.features[.power].isAvailable }
        #expect(snapshot.power == .absent(.notOnConsole))
        #expect(await harness.hub.requestPower(.shutdown) == .useACPI(refusals: []))
        await close([session, system], harness)
    }
}
