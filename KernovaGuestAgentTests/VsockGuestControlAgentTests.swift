import Testing
import Foundation
import Darwin
import KernovaProtocol

@Suite("VsockGuestControlAgent")
struct VsockGuestControlAgentTests {

    // MARK: - Helpers

    /// Builds a host-side Hello frame for the agent to consume.
    private func makeHostHelloFrame() -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities = ["control.v1", "control.heartbeat.v1"]
            $0.agentInfo = Kernova_V1_AgentInfo.with {
                $0.os = "macOS"
                $0.osVersion = "26.0"
                $0.agentVersion = "host"
            }
        }
        return frame
    }

    private func makeHeartbeatFrame(nonce: UInt64 = 1) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.heartbeat = Kernova_V1_Heartbeat.with { $0.nonce = nonce }
        return frame
    }

    /// Builds a single-fd-shot agent at small test cadences. The agent's
    /// `client` provider hands `agentFd` on the first call, transient failure
    /// after — so reconnect tests must use a multi-fd provider explicitly.
    private func makeAgent(
        agentFd: Int32,
        heartbeatInterval: Duration = .milliseconds(40),
        unresponsiveAfter: Duration = .milliseconds(160),
        terminateAfter: Duration = .milliseconds(2_000)
    ) -> VsockGuestControlAgent {
        let provided = AtomicInt()
        let client = VsockGuestClient(
            port: KernovaVsockPort.control,
            label: "control-test",
            retryInterval: .seconds(60)
        ) { _, _ in
            provided.increment() == 1 ? .success(agentFd) : .failure(.transient("test: no fd"))
        }
        return VsockGuestControlAgent(
            client: client,
            heartbeatInterval: heartbeatInterval,
            unresponsiveAfter: unresponsiveAfter,
            terminateAfter: terminateAfter
        )
    }

    // MARK: - Hello

    @Test("Sends guest Hello on connect with control capabilities")
    func sendsGuestHelloOnConnect() async throws {
        let (agentFd, hostFd) = try makeRawSocketPair()
        let host = VsockChannel(fileDescriptor: hostFd)
        host.start()
        defer { host.close() }

        let agent = makeAgent(agentFd: agentFd)
        defer { agent.stop() }
        agent.start()

        let received = try await nextFrame(from: host)
        guard case .hello(let hello) = received.payload else {
            throw TestFailure("Expected Hello, got \(String(describing: received.payload))")
        }
        #expect(hello.capabilities.contains("control.v1"))
        #expect(hello.capabilities.contains("control.heartbeat.v1"))
    }

    // MARK: - Heartbeat

    @Test("Emits heartbeat frames on the configured cadence")
    func heartbeatOutboundCadence() async throws {
        let (agentFd, hostFd) = try makeRawSocketPair()
        let host = VsockChannel(fileDescriptor: hostFd)
        host.start()
        defer { host.close() }

        let agent = makeAgent(agentFd: agentFd, heartbeatInterval: .milliseconds(30))
        defer { agent.stop() }
        agent.start()

        // First frame is the agent Hello — discard.
        _ = try await nextFrame(from: host)

        // Within ~150ms (5 cadences) we should see at least 3 heartbeats.
        // Slack accounts for scheduler jitter without making the assertion vacuous.
        var count = 0
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        while ContinuousClock.now < deadline && count < 3 {
            let frame = try await nextFrame(from: host, timeout: .milliseconds(200))
            if case .heartbeat = frame.payload {
                count += 1
            }
        }
        #expect(count >= 3, "Expected at least 3 heartbeats; got \(count)")
    }

    // MARK: - Inbound

    @Test("Inbound host Hello and Heartbeat are accepted without crashing")
    func inboundFramesAccepted() async throws {
        let (agentFd, hostFd) = try makeRawSocketPair()
        let host = VsockChannel(fileDescriptor: hostFd)
        host.start()
        defer { host.close() }

        let agent = makeAgent(agentFd: agentFd)
        defer { agent.stop() }
        agent.start()

        // Discard agent's outbound Hello.
        _ = try await nextFrame(from: host)

        // Send host Hello + a few heartbeats. Behaviorally we just verify the
        // agent stays connected (its outbound heartbeat stream keeps flowing).
        try host.send(makeHostHelloFrame())
        for n in 1 ... 3 {
            try host.send(makeHeartbeatFrame(nonce: UInt64(n)))
            try await Task.sleep(for: .milliseconds(40))
        }

        // The agent should still be sending heartbeats: read the next frame
        // and expect either a heartbeat or — at worst — a successful round
        // trip without a thrown error.
        let frame = try await nextFrame(from: host, timeout: .milliseconds(200))
        switch frame.payload {
        case .heartbeat:
            break
        default:
            throw TestFailure("Expected heartbeat from agent after inbound traffic; got \(String(describing: frame.payload))")
        }
    }

    // MARK: - Liveness teardown + reconnect

    @Test("Silent host past terminateAfter closes the channel; client reconnects with a fresh Hello")
    func unresponsiveHostTriggersReconnect() async throws {
        let (agentFd0, _hostFd0) = try makeRawSocketPair()
        let (agentFd1, hostFd1) = try makeRawSocketPair()

        // Close the first host fd immediately so any agent send to host0
        // doesn't stall the test on a kernel buffer; the agent's liveness
        // watchdog tears down its own end after `terminateAfter` of silence.
        // RATIONALE: We're testing the agent's behavior on a silent host —
        // closing host0 simulates an unresponsive peer cleanly, but the
        // critical path is the watchdog timeout, not the EOF.
        close(_hostFd0)

        let host1 = VsockChannel(fileDescriptor: hostFd1)
        host1.start()
        defer { host1.close() }

        let fdBox = FdBox(fds: [agentFd0, agentFd1])
        let provideCount = AtomicInt()

        let client = VsockGuestClient(
            port: KernovaVsockPort.control,
            label: "control-reconnect-test",
            retryInterval: .milliseconds(50)
        ) { _, _ in
            let n = provideCount.increment()
            if let fd = fdBox.fd(at: n - 1) {
                return .success(fd)
            } else {
                return .failure(.transient("test: no fd at index \(n - 1)"))
            }
        }

        let agent = VsockGuestControlAgent(
            client: client,
            heartbeatInterval: .milliseconds(40),
            unresponsiveAfter: .milliseconds(80),
            terminateAfter: .milliseconds(200)
        )
        defer { agent.stop() }
        agent.start()

        // The first connection has a closed peer. The agent's heartbeat-send
        // failures plus the liveness watchdog will tear down the channel.
        // The client then reconnects with the second fd. Wait for the agent's
        // Hello on host1 — proof the reconnect cycle ran end to end.
        let firstFrame = try await nextFrame(from: host1, timeout: .seconds(3))
        guard case .hello(let hello) = firstFrame.payload else {
            throw TestFailure("Expected Hello on reconnect, got \(String(describing: firstFrame.payload))")
        }
        #expect(hello.capabilities.contains("control.v1"))
        #expect(provideCount.value >= 2)
    }

    // MARK: - Lifecycle

    @Test("stop() halts the connection without throwing")
    func stopHaltsCleanly() async throws {
        let (agentFd, hostFd) = try makeRawSocketPair()
        let host = VsockChannel(fileDescriptor: hostFd)
        host.start()
        defer { host.close() }

        let agent = makeAgent(agentFd: agentFd)
        agent.start()

        _ = try await nextFrame(from: host)
        agent.stop()
        // Second stop is a no-op.
        agent.stop()
    }
}
