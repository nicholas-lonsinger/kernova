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
    _ stream: ScriptedStream, queues: [DispatchQueue], fileID: String = #fileID, line: Int = #line,
    read: (Data) -> Void, output: () -> Data
) async throws {
    var calls = stream.calls.waiter()
    _ = try await calls.next(fileID: fileID, line: line) { $0 == "start" }
    var idle = 0
    while idle < 2 {
        for _ in 0..<2 {
            for queue in queues { try await flush(queue, fileID: fileID, line: line) }
            if let queue = stream.queue { try await flush(queue, fileID: fileID, line: line) }
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
    let stops = Recorder<StopReason>()
    let runtime: PeerAgentRuntime

    init() {
        let stops = stops
        runtime = PeerAgentRuntime(
            claim: Fixture.peerClaim, state: Fixture.peerState,
            registry: PeerFeatureRegistry(power: FakePowerAdapter(handsOff: false)), dialer: dialer,
            scheduler: scheduler, logger: Fixture.logger,
            handlers: PeerAgentRuntime.Handlers(stop: { stops.record($0) }))
    }

    /// Runs every block already on the runtime's queue.
    func settle(fileID: String = #fileID, line: Int = #line) async throws {
        try await flush(runtime.queue, fileID: fileID, line: line)
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
            case .role(.update(.payload(let id, let bytes))):
                endpoint.handle(.update(.consumed(id, bytes.count)), now: now)
            case .role(.update(.complete(let id, _))): endpoint.handle(.update(.installed(id)), now: now)
            case .role, .itemSource, .itemSink: break
            }
        }
        while endpoint.pollEvent() != nil {}
    }
}
