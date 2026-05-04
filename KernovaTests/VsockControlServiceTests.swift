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
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { buf in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        guard rc == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return (VsockChannel(fileDescriptor: fds[0]),
                VsockChannel(fileDescriptor: fds[1]))
    }

    private func nextFrame(
        from channel: VsockChannel,
        timeout: Duration = .seconds(2)
    ) async throws -> Frame {
        let receiver = Task<Frame?, Error> {
            var iterator = channel.incoming.makeAsyncIterator()
            return try await iterator.next()
        }
        let timeoutTask = Task<Void, Error> {
            try await Task.sleep(for: timeout)
            receiver.cancel()
        }
        defer { timeoutTask.cancel() }
        guard let frame = try await receiver.value else {
            throw TestFailure("Channel finished without producing a frame")
        }
        return frame
    }

    private struct TestFailure: Error { let message: String; init(_ m: String) { message = m } }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if !predicate() {
            throw TestFailure("Predicate did not become true within \(timeout)")
        }
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

        let service = makeService(channel: host, heartbeatInterval: .milliseconds(30))
        service.start()
        defer { service.stop() }

        // Frame 0 is the host Hello. After that, three heartbeats with a 30ms
        // cadence should arrive within ~250ms (slack for scheduler jitter).
        _ = try await nextFrame(from: guest)

        var heartbeatCount = 0
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(400))
        while heartbeatCount < 3, ContinuousClock.now < deadline {
            let frame = try await nextFrame(from: guest, timeout: .milliseconds(300))
            if case .heartbeat = frame.payload {
                heartbeatCount += 1
            }
        }
        #expect(heartbeatCount >= 3, "Expected at least 3 heartbeats; got \(heartbeatCount)")
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
        try await waitUntil(timeout: .seconds(2)) {
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
        try await waitUntil(timeout: .seconds(2)) {
            service.agentStatus == .unresponsive(version: "0.9.0")
        }

        // Resume heartbeats. The next liveness tick clears the flag.
        try guest.send(makeHeartbeat(nonce: 99))
        try await waitUntil(timeout: .seconds(2)) {
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

        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            heartbeatInterval: .milliseconds(40),
            unresponsiveAfter: .milliseconds(80),
            terminateAfter: .milliseconds(200)
        )

        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest) // host hello
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitUntil { service.isConnected }

        // Wait for a couple of terminateAfter windows. By then `checkLiveness`
        // should have fired and called `channel.close()` on the host side.
        // After teardown, `host.send(...)` raises `VsockChannelError.closed`.
        try await waitUntil(timeout: .seconds(2)) {
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
