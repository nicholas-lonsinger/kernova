#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaWire
import Testing

/// The peer runtime's dial schedule and connection handling, on scripted streams and a manual clock, on
/// every OS.
@Suite("Peer agent runtime")
struct PeerAgentRuntimeTests {
    @Test("close() with no connection completes at once, and a dial it outlived is shut down unstarted")
    func closeDuringDial() async throws {
        let harness = PeerRuntimeHarness()
        harness.runtime.start()
        var dials = harness.dialer.dials.waiter()
        _ = try await dials.next { $0 == 1 }
        let completions = Recorder<Int>()
        harness.runtime.close { completions.record(1) }
        var done = completions.waiter()
        _ = try await done.next { _ in true }

        let stream = ScriptedStream()
        harness.dialer.answer(1, .success(stream))
        try await harness.settle()
        #expect(stream.calls.elements == ["shutdown"])
        #expect(harness.scheduler.armed.isEmpty)
        #expect(harness.stops.elements.isEmpty)
    }
}

/// The host runtime over a scripted stream, on every OS.
@Suite("Host connection runtime")
struct HostConnectionRuntimeTests {
    static let manifest = UpdateManifestValue(
        payloadHash: Data(repeating: 0xC3, count: 32), payloadSize: 3 * 1_048_576, format: .executable)

    final class Harness: Sendable {
        let scheduler = ManualScheduler(now: Fixture.t0)
        let stream = ScriptedStream()
        let far: FarPeer
        let hub = DispatchQueue(label: "app.kernova.tests.hub")
        let events = Recorder<HostEvent>()
        let source: FakePayloadSource
        let connection: HostConnection

        init(content: Data, items: ItemAdapters? = nil) {
            far = FarPeer(clock: scheduler)
            source = FakePayloadSource(content: content)
            let runtime = HostConnectionRuntime(
                claim: Fixture.hostClaim, scheduler: scheduler, payloadSource: source, items: items,
                logger: Fixture.logger)
            let events = events
            connection = runtime.makeConnection(
                stream, policy: PolicySnapshot(),
                bundles: [
                    BundledPayload(
                        os: .linux, architecture: .arm64, scope: .user, manifest: manifest, updatesInBand: true)
                ],
                deliveringOn: hub
            ) { events.record($0) }
            connection.start()
        }

        func pump() async throws {
            try await exchange(stream, queues: [hub], read: far.read, output: far.output)
        }
    }

    @Test("A source that runs out short of the payload's size fails the pull READ_FAILED")
    func shortSourceFails() async throws {
        let harness = Harness(content: FakePayloadSource.payload(1_048_576 + 7))
        try await harness.pump()
        var events = harness.events.waiter()
        let closed = try await events.next {
            if case .role(.update(.closed)) = $0 { return true }
            return false
        }
        guard case .role(.update(.closed(_, .resetLocally(let error)))) = closed else {
            Issue.record("the pull ended \(closed)")
            return
        }
        #expect(error.code == .readFailed)
    }
}
