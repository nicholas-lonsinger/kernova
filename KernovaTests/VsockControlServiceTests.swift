import Testing
import Foundation
import Darwin
import KernovaProtocol
@testable import Kernova

@Suite("VsockControlService")
@MainActor
struct VsockControlServiceTests {

    // MARK: - Helpers

    private func makePair() throws -> (sender: VsockChannel, receiver: VsockChannel) {
        let (a, b) = try makeRawSocketPair()
        return (VsockChannel(fileDescriptor: a), VsockChannel(fileDescriptor: b))
    }

    /// Builds a guest-side Hello frame with the given agent version. Tests use
    /// this to drive the `agentStatus` numeric-comparison matrix.
    private func makeGuestHello(agentVersion: String) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities = ["control.v1", "control.heartbeat.v1"]
            $0.agentInfo = Kernova_V1_AgentInfo.with {
                $0.os = "macOS"
                $0.osVersion = "26.0"
                $0.agentVersion = agentVersion
            }
        }
        return frame
    }

    private func makeHeartbeat(nonce: UInt64 = 1) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.heartbeat = Kernova_V1_Heartbeat.with { $0.nonce = nonce }
        return frame
    }

    /// Default test cadences. Small enough that liveness assertions don't
    /// drag the suite, large enough to avoid scheduler-induced flakiness.
    private static let testHeartbeat: Duration = .milliseconds(40)
    private static let testUnresponsive: Duration = .milliseconds(160)
    private static let testTerminate: Duration = .milliseconds(400)

    /// Builds a service with the test cadences applied. Caller decides
    /// `bundledAgentVersion`. The service is NOT started — caller invokes
    /// `start()` after wiring the recorder.
    private func makeService(
        channel: VsockChannel,
        bundledAgentVersion: String? = "0.9.0",
        heartbeatInterval: Duration? = nil,
        unresponsiveAfter: Duration? = nil,
        terminateAfter: Duration? = nil
    ) -> VsockControlService {
        VsockControlService(
            channel: channel,
            label: "test",
            bundledAgentVersion: bundledAgentVersion,
            heartbeatInterval: heartbeatInterval ?? Self.testHeartbeat,
            unresponsiveAfter: unresponsiveAfter ?? Self.testUnresponsive,
            terminateAfter: terminateAfter ?? Self.testTerminate
        )
    }

    // MARK: - Hello

    @Test("Sends host Hello on start with control capabilities")
    func sendsHostHelloOnStart() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = makeService(channel: host)
        service.start()
        defer { service.stop() }

        let received = try await nextFrame(from: guest)
        guard case .hello(let hello) = received.payload else {
            Issue.record("Expected hello payload, got \(String(describing: received.payload))")
            return
        }
        #expect(hello.capabilities.contains("control.v1"))
        #expect(hello.capabilities.contains("control.heartbeat.v1"))
    }

    @Test("Guest hello flips isConnected and populates agentVersion")
    func guestHelloPopulatesState() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = makeService(channel: host)
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest) // host hello
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))

        try await waitUntil { service.isConnected }
        #expect(service.isConnected)
        #expect(service.agentVersion == "0.9.0")
    }

    // MARK: - agentStatus matrix

    @Test("agentStatus is .waiting before guest Hello arrives")
    func agentStatusWaitingBeforeHello() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = makeService(channel: host)
        service.start()
        defer { service.stop() }

        #expect(service.agentStatus == .waiting)
    }

    @Test("agentStatus is .current when guest reports the bundled version")
    func agentStatusCurrentWhenVersionsMatch() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = makeService(channel: host, bundledAgentVersion: "0.9.0")
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitUntil { service.isConnected }

        #expect(service.agentStatus == .current(version: "0.9.0"))
    }

    @Test("agentStatus is .outdated when guest reports an older version")
    func agentStatusOutdatedWhenGuestOlder() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = makeService(channel: host, bundledAgentVersion: "0.9.0")
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)
        try guest.send(makeGuestHello(agentVersion: "0.8.5"))
        try await waitUntil { service.isConnected }

        #expect(service.agentStatus == .outdated(installed: "0.8.5", bundled: "0.9.0"))
    }

    @Test("agentStatus is .current when guest reports a newer version")
    func agentStatusCurrentWhenGuestNewer() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = makeService(channel: host, bundledAgentVersion: "0.9.0")
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)
        try guest.send(makeGuestHello(agentVersion: "1.0.0"))
        try await waitUntil { service.isConnected }

        // Newer-than-bundled should not flag .outdated against the user.
        #expect(service.agentStatus == .current(version: "1.0.0"))
    }

    @Test("agentStatus uses numeric ordering: 0.9.0 < 0.10.0")
    func agentStatusNumericOrdering() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = makeService(channel: host, bundledAgentVersion: "0.10.0")
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitUntil { service.isConnected }

        // Lexicographic compare would put "0.9.0" > "0.10.0" — wrong.
        #expect(service.agentStatus == .outdated(installed: "0.9.0", bundled: "0.10.0"))
    }

    @Test("agentStatus falls back to .current when bundled version is unavailable")
    func agentStatusCurrentWhenBundledMissing() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = makeService(channel: host, bundledAgentVersion: nil)
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)
        try guest.send(makeGuestHello(agentVersion: "0.5.0"))
        try await waitUntil { service.isConnected }

        // Without a bundled version to compare against, accept the guest's
        // report rather than prompting the user to "update" against missing data.
        #expect(service.agentStatus == .current(version: "0.5.0"))
    }

    @Test("agentStatus resets to .waiting on stop()")
    func agentStatusResetsOnStop() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = makeService(channel: host, bundledAgentVersion: "0.9.0")
        service.start()

        _ = try await nextFrame(from: guest)
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitUntil { service.isConnected }
        #expect(service.agentStatus == .current(version: "0.9.0"))

        service.stop()
        #expect(service.agentStatus == .waiting)
    }

    // MARK: - Heartbeat

    @Test("Sends heartbeat frames on the configured cadence")
    func heartbeatOutboundCadence() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // Property under test: heartbeats fire repeatedly on the cadence.
        //
        // Earlier shape — "≥ N heartbeats inside a fixed wall-clock window" —
        // was brittle on macos-26 runners. Gap-based: read three consecutive
        // heartbeats and check that the maximum inter-frame gap stays within
        // a generous tolerance of the cadence. Mirrors the agent-side test
        // in VsockGuestControlAgentTests.
        //
        // Note: gaps are measured at receive time, not at the timer's fire
        // time. A MainActor stall that buffers frames and drains them back-
        // to-back will pass — correct for "is the timer running" but not a
        // check on end-to-end latency.
        let cadence: Duration = .milliseconds(100)
        let service = makeService(channel: host, heartbeatInterval: cadence)
        service.start()
        defer { service.stop() }

        // Frame 0 is the host Hello — discard.
        _ = try await nextFrame(from: guest)

        var stamps: [ContinuousClock.Instant] = []
        while stamps.count < 3 {
            // Use the shared 5 s default. If the timer is genuinely broken
            // we'll still fail in bounded time (≤15 s); if it's just slow,
            // returning the frame lets the maxGap assertion below produce a
            // sharper "cadence drift" error than a generic timeout.
            let frame = try await nextFrame(from: guest)
            if case .heartbeat = frame.payload {
                stamps.append(.now)
            }
        }

        // Loop above guarantees stamps.count == 3, so gaps has exactly 2
        // elements and reduce(.zero, max) is the natural non-optional form.
        let gaps = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        let maxGap = gaps.reduce(.zero, max)
        let tolerance = cadence * 10
        #expect(
            maxGap < tolerance,
            "Heartbeat cadence drift: max gap \(maxGap) exceeds \(tolerance) (10× cadence). Gaps: \(gaps)"
        )
    }

    @Test("Inbound heartbeat keeps agentStatus .current past unresponsiveAfter")
    func inboundHeartbeatPreservesLiveness() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // Use generous timings so MainActor scheduling jitter on slow CI
        // runners doesn't race the watchdog tick. The narrow 40 ms / 120 ms
        // pairing this test originally used was flaky on GitHub Actions:
        // when the test's `Task.sleep` resumed late (because MainActor was
        // busy with the heartbeat + liveness tasks), `now - lastInboundFrame`
        // could exceed `unresponsiveAfter` between sleep wake and assertion,
        // flipping status to .unresponsive briefly even though the test had
        // just sent a heartbeat. Widening the unresponsive window to 400 ms
        // and asserting only at end-of-test (rather than per-iteration)
        // removes the race while still proving the property under test:
        // sustained inbound heartbeats reset the inbound-liveness clock so
        // status remains .current across a window > unresponsiveAfter.
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            heartbeatInterval: .milliseconds(200),
            unresponsiveAfter: .milliseconds(400),
            terminateAfter: .seconds(5)
        )
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitUntil { service.isConnected }

        // Send heartbeats every 100 ms (well below the 400 ms unresponsive
        // window) for ~800 ms total — twice unresponsiveAfter.
        for nonce in 1 ... 8 {
            try guest.send(makeHeartbeat(nonce: UInt64(nonce)))
            try await Task.sleep(for: .milliseconds(100))
        }

        // End-state check: total elapsed > 2× unresponsiveAfter. If
        // heartbeats had not been resetting the clock, status would now be
        // .unresponsive. .current here proves the sustained-liveness path.
        #expect(service.agentStatus == .current(version: "0.9.0"))
    }

    @Test("Silence past unresponsiveAfter flips agentStatus to .unresponsive")
    func silenceMarksUnresponsive() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            heartbeatInterval: .milliseconds(60),
            unresponsiveAfter: .milliseconds(100),
            terminateAfter: .milliseconds(2_000)
        )
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitUntil { service.isConnected }

        // Don't send any further inbound. After ~100ms+ the watchdog flips.
        try await waitUntil(timeout: .seconds(5)) {
            service.agentStatus == .unresponsive(version: "0.9.0")
        }
        #expect(service.agentStatus == .unresponsive(version: "0.9.0"))
    }

    @Test("Resumed heartbeats restore agentStatus to .current")
    func recoveryFromUnresponsive() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            heartbeatInterval: .milliseconds(60),
            unresponsiveAfter: .milliseconds(100),
            terminateAfter: .milliseconds(2_000)
        )
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitUntil { service.isConnected }

        // Go silent → unresponsive.
        try await waitUntil(timeout: .seconds(5)) {
            service.agentStatus == .unresponsive(version: "0.9.0")
        }

        // Resume heartbeats. The next liveness tick clears the flag.
        try guest.send(makeHeartbeat(nonce: 99))
        try await waitUntil(timeout: .seconds(5)) {
            service.agentStatus == .current(version: "0.9.0")
        }
        #expect(service.agentStatus == .current(version: "0.9.0"))
    }

    @Test("Silence past terminateAfter closes the host channel")
    func terminateClosesChannel() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // Widen cadences for CI runner jitter (the original 40/80/200 ms
        // pairing was tight enough that on slow runners the watchdog could
        // miss its window before the terminate condition fired).
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            heartbeatInterval: .milliseconds(100),
            unresponsiveAfter: .milliseconds(200),
            terminateAfter: .milliseconds(500)
        )

        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest) // host hello
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitUntil { service.isConnected }

        // Wait for a few terminateAfter windows. By then `checkLiveness`
        // should have fired and called `channel.close()` on the host side.
        // After teardown, `host.send(...)` raises `VsockChannelError.closed`.
        try await waitUntil(timeout: .seconds(5)) {
            do {
                try host.send(makeHeartbeat(nonce: 1))
                return false
            } catch {
                return true
            }
        }
    }

    // MARK: - Lifecycle

    @Test("stop() is idempotent and resets state")
    func stopIsIdempotent() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = makeService(channel: host, bundledAgentVersion: "0.9.0")
        service.start()

        _ = try await nextFrame(from: guest)
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitUntil { service.isConnected }

        service.stop()
        #expect(!service.isConnected)
        #expect(service.agentVersion == nil)
        #expect(service.agentStatus == .waiting)

        // Second stop() is a no-op.
        service.stop()
        #expect(!service.isConnected)
    }
}
