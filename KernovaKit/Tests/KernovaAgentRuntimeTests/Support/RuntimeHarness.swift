#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaSynchronization
import KernovaWire

/// Moves bytes between a scripted stream and its far side until neither has anything left to send.
///
/// Everything a runtime does follows from the test's own steps on a manual clock, so the queues settle:
/// once the stream has started (its start queue is the driver queue), a round flushes each queue twice in
/// turn, and two rounds that move nothing end the pump.
func exchange(
    _ stream: ScriptedStream, queues: [DispatchQueue], read: (Data) -> Void, output: () -> Data
) async {
    var calls = stream.calls.waiter()
    _ = await calls.next { $0 == "start" }
    var idle = 0
    while idle < 2 {
        for _ in 0..<2 {
            for queue in queues { await flush(queue) }
            if let queue = stream.queue { await flush(queue) }
        }
        var moved = false
        if stream.hasPendingWrite {
            let written = stream.takeWritten()
            stream.completeWrite()
            read(written)
            moved = true
        }
        let bytes = output()
        if !bytes.isEmpty {
            stream.deliver(.received(bytes))
            moved = true
        }
        idle = moved ? 0 : idle + 1
    }
}

/// A `PeerAgentRuntime` on a manual clock, dialing through a scripted dialer.
final class PeerRuntimeHarness: Sendable {
    let scheduler = ManualScheduler(now: Fixture.t0)
    let dialer = ScriptedDialer()
    let power: FakePowerAdapter
    let events = Recorder<PeerEvent>()
    let stops = Recorder<StopReason>()
    let runtime: PeerAgentRuntime

    init(
        power: FakePowerAdapter = FakePowerAdapter(handsOff: false), state: PeerSessionState? = Fixture.peerState
    ) {
        self.power = power
        let events = events
        let stops = stops
        runtime = PeerAgentRuntime(
            claim: Fixture.peerClaim, state: state, registry: PeerFeatureRegistry(power: power),
            dialer: dialer, scheduler: scheduler, logger: Fixture.logger,
            handlers: PeerAgentRuntime.Handlers(event: { events.record($0) }, stop: { stops.record($0) }))
    }

    /// Runs every block already on the runtime's queue.
    func settle() async {
        await flush(runtime.queue)
    }

    /// Answers dial `number` with a new link and pumps it through the Hello.
    func connect(_ number: Int) async -> RuntimeLink {
        var dials = dialer.dials.waiter()
        _ = await dials.next { $0 == number }
        let link = RuntimeLink(clock: scheduler)
        dialer.answer(number, .success(link.stream))
        var calls = link.stream.calls.waiter()
        _ = await calls.next { $0 == "start" }
        await pump(link)
        return link
    }

    /// Pumps `link` until it is quiet.
    func pump(_ link: RuntimeLink) async {
        await exchange(
            link.stream, queues: [runtime.queue], read: link.far.read, output: link.far.output)
    }
}

/// One dialed stream and the host endpoint on its far side.
final class RuntimeLink: Sendable {
    let stream = ScriptedStream()
    let far: FarHost

    init(clock: ManualScheduler) {
        far = FarHost(clock: clock)
    }
}

/// A peer endpoint the test runs by hand as the far side of a host connection: it writes every payload
/// byte at once and installs what completes.
final class FarPeer: Sendable {
    private let endpoint: Locked<PeerEndpoint>
    private let clock: ManualScheduler

    init(clock: ManualScheduler) {
        self.clock = clock
        let configuration = PeerConfiguration(
            claim: Fixture.peerClaim, state: Fixture.peerState, power: .absent(.notImplemented, debugDetail: ""),
            logs: .absent(.notImplemented, debugDetail: ""), update: .available(UpdateOffer(formats: [.executable])))
        endpoint = Locked(PeerEndpoint(configuration, generation: ConnectionGeneration(rawValue: 1), now: clock.now))
    }

    func read(_ bytes: Data) {
        let now = clock.now
        endpoint.withLock { endpoint in
            endpoint.receive(bytes, now: now)
            Self.answer(&endpoint, now)
        }
    }

    func output() -> Data {
        let now = clock.now
        return endpoint.withLock { endpoint in
            var bytes = Data()
            while let transmit = endpoint.pollTransmit(maxBytes: 1 << 20) {
                for chunk in transmit.chunks { bytes.append(chunk) }
                Self.answer(&endpoint, now)
            }
            return bytes
        }
    }

    private static func answer(_ endpoint: inout PeerEndpoint, _ now: CoreInstant) {
        while let effect = endpoint.pollEffect() {
            switch effect {
            case .update(.payload(let id, let bytes)): endpoint.handle(.update(.consumed(id, bytes.count)), now: now)
            case .update(.complete(let id, _)): endpoint.handle(.update(.installed(id)), now: now)
            case .power, .logs, .update: break
            }
        }
        while endpoint.pollEvent() != nil {}
    }
}
