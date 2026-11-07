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
        #expect(await harness.hub.requestPower(.shutdown) == .untaken(refusals: []))
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

        guard case .untaken(let refusals) = await outcome else {
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
        #expect(
            accepted.routing
                == PowerRoutingProgress(action: .shutdown, ignoringApps: false, role: .sessionPeer, stage: .accepted))
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

    @Test("With a user logged in, only the system peer shuts down without waiting for apps, and the snapshot says so")
    func systemPeerShutsDownIgnoringApps() async {
        let harness = HubHarness()
        await harness.attached()
        let sessionPower = FakePowerAdapter()
        let systemPower = FakePowerAdapter(
            initial: .available(PowerOffer(actions: [], ignoringApps: [.shutdown])))
        let session = await connect(harness, sessionPower)
        let system = await connect(
            harness, systemPower, claim: Self.systemClaim,
            state: PeerSessionState(console: .on, consoleSessionID: "1"), peers: 2)
        let ready = await harness.snapshot { $0.shutsDownIgnoringApps }
        // A graceful shutdown still goes to the console session's peer.
        #expect(ready.power == .agent(.sessionPeer))

        #expect(await harness.hub.requestPower(.shutdown, ignoringApps: true) == .handedOff)
        #expect(systemPower.performedIgnoringApps.elements.count == 1)
        #expect(sessionPower.performed.elements.isEmpty)
        await close([session, system], harness)
    }

    @Test("With no peer offering it, a shutdown without waiting for apps asks no one and is untaken")
    func nothingShutsDownIgnoringApps() async {
        let harness = HubHarness()
        await harness.attached()
        let power = FakePowerAdapter()
        let session = await connect(harness, power)
        let ready = await harness.snapshot { $0.power == .agent(.sessionPeer) }
        #expect(!ready.shutsDownIgnoringApps)

        #expect(await harness.hub.requestPower(.shutdown, ignoringApps: true) == .untaken(refusals: []))
        #expect(power.performed.elements.isEmpty)
        await close([session], harness)
    }

    @Test(
        "At a login window, with only a background session's peer and the system peer, a graceful action asks no one and is untaken"
    )
    func loginWindowGracefulUntaken() async {
        let harness = HubHarness()
        await harness.attached()
        let sessionPower = FakePowerAdapter(initial: .available(PowerOffer(actions: [.shutdown, .restart])))
        let systemPower = FakePowerAdapter(
            initial: .available(PowerOffer(actions: [], ignoringApps: [.shutdown])))
        let session = await connect(
            harness, sessionPower, state: PeerSessionState(console: .off, sessionID: "1", userName: "user"))
        let system = await connect(
            harness, systemPower, claim: Self.systemClaim, state: PeerSessionState(console: .off), peers: 2)
        let ready = await harness.snapshot { $0.shutsDownIgnoringApps }
        #expect(ready.power == .absent(.notOnConsole))

        #expect(await harness.hub.requestPower(.shutdown) == .untaken(refusals: []))
        #expect(await harness.hub.requestPower(.restart) == .untaken(refusals: []))
        #expect(sessionPower.performed.elements.isEmpty)
        #expect(systemPower.performed.elements.isEmpty)

        #expect(await harness.hub.requestPower(.shutdown, ignoringApps: true) == .handedOff)
        #expect(systemPower.performedIgnoringApps.elements.count == 1)
        await close([session, system], harness)
    }

    @Test(
        "A macOS system peer reporting the console on without naming a session leaves the console to the session peers' reports"
    )
    func macOSSystemPeerConsoleOnUnnamed() async {
        let harness = HubHarness()
        await harness.attached()
        let systemClaim = PeerClaim(role: .systemPeer, scope: .system, os: .macOS, architecture: .arm64)
        let systemPower = FakePowerAdapter(initial: .available(PowerOffer(actions: [], ignoringApps: [.shutdown])))
        let system = await connect(
            harness, systemPower, claim: systemClaim, state: PeerSessionState(console: .on), peers: 1)
        // Beside no session peer: nothing takes a graceful shutdown, and the system peer takes the one ignoring apps.
        let alone = await harness.snapshot { $0.shutsDownIgnoringApps }
        #expect(alone.power == .absent(.notOnConsole))
        #expect(await harness.hub.requestPower(.shutdown) == .untaken(refusals: []))
        #expect(systemPower.performed.elements.isEmpty)

        // Beside the console session's peer: it takes the graceful shutdown; the system peer, the one ignoring apps.
        let sessionPower = FakePowerAdapter()
        let session = await connect(harness, sessionPower, peers: 2)
        let ready = await harness.snapshot { $0.power == .agent(.sessionPeer) }
        #expect(ready.shutsDownIgnoringApps)
        #expect(await harness.hub.requestPower(.shutdown) == .handedOff)
        #expect(sessionPower.performed.elements.count == 1)
        #expect(await harness.hub.requestPower(.shutdown, ignoringApps: true) == .handedOff)
        #expect(systemPower.performedIgnoringApps.elements.count == 1)
        await close([session, system], harness)
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
        #expect(await harness.hub.requestPower(.shutdown) == .untaken(refusals: []))
        await close([session, system], harness)
    }
}
