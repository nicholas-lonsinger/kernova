import Testing
import Foundation
import Darwin
import KernovaKit
import KernovaTestSupport

@Suite("VsockGuestControlAgent")
struct VsockGuestControlAgentTests {
    // MARK: - Helpers

    /// Builds a host-side Hello frame for the agent to consume.
    private func makeHostHelloFrame(
        streamingCapable: Bool = true, bundledAgentVersion: String = ""
    ) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities =
                streamingCapable
                ? KernovaCapability.controlChannelDefaults
                : [KernovaCapability.controlV1, KernovaCapability.controlHeartbeatV1]
            $0.bundledAgentVersion = bundledAgentVersion
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

    /// Default outbound-heartbeat cadence: small so `heartbeatOutboundCadence`
    /// doesn't drag, and harmless to every other test (extra heartbeats only
    /// keep the connection alive).
    private static let testHeartbeat: Duration = .milliseconds(40)

    /// Default liveness windows, set far beyond any test's wall-clock budget.
    ///
    /// The watchdog can't tear the channel down mid-test at these values. Tests
    /// that *exercise* the watchdog pass explicit short windows to opt back in.
    ///
    /// The watchdog measures `ContinuousClock.now - lastInboundFrame`, which
    /// keeps advancing while a contended CI MainActor stalls the test. With a
    /// short default, any non-watchdog test that paused past the window saw the
    /// channel closed out from under it — surfacing as an EOF / `.closed` flake.
    /// Making the watchdog an explicit opt-in removes that coupling. Mirrors
    /// `VsockControlServiceTests` / `makeService`. See docs/TESTING.md "Async waits in tests".
    private static let watchdogDisabledUnresponsive: Duration = .seconds(3_600)
    private static let watchdogDisabledTerminate: Duration = .seconds(7_200)

    /// Builds a single-fd-shot agent with the liveness watchdog disabled by
    /// default.
    ///
    /// The agent's
    /// `client` provider hands `agentFd` on the first call, transient failure
    /// after — so reconnect tests must use a multi-fd provider explicitly.
    private func makeAgent(
        agentFd: Int32,
        heartbeatInterval: Duration? = nil,
        unresponsiveAfter: Duration? = nil,
        terminateAfter: Duration? = nil,
        onPolicy: (@Sendable (Kernova_V1_PolicyUpdate) -> Void)? = nil,
        onStateChange: (@Sendable (HostConnectionState) -> Void)? = nil
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
            heartbeatInterval: heartbeatInterval ?? Self.testHeartbeat,
            unresponsiveAfter: unresponsiveAfter ?? Self.watchdogDisabledUnresponsive,
            terminateAfter: terminateAfter ?? Self.watchdogDisabledTerminate,
            onPolicy: onPolicy,
            onStateChange: onStateChange
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
        // The guest advertises streaming-clipboard support so the host can gate
        // clipboard on it.
        #expect(hello.capabilities.contains(KernovaCapability.clipboardStreamV1))
    }

    // MARK: - Heartbeat

    @Test("Emits heartbeat frames on the configured cadence")
    func heartbeatOutboundCadence() async throws {
        let (agentFd, hostFd) = try makeRawSocketPair()
        let host = VsockChannel(fileDescriptor: hostFd)
        host.start()
        defer { host.close() }

        // Property under test: heartbeats fire repeatedly on the cadence.
        //
        // Earlier shape — "≥ N heartbeats inside a fixed wall-clock window" —
        // was brittle on macos-26 GitHub Actions runners (one prior failure
        // recorded `count → 2 ≥ 3`). The window-based count fails when a
        // single MainActor stall slides multiple ticks outside the window
        // even though the timer is firing correctly.
        //
        // Gap-based assertion: read three consecutive heartbeats and check
        // that the maximum inter-frame gap stays within a generous tolerance
        // of the cadence. This proves "the timer fires repeatedly at roughly
        // the configured rate" without coupling to absolute wall-clock time.
        //
        // Note: gaps are measured at receive time, not at the timer's fire
        // time. If MainActor stalls and the kernel buffers heartbeats during
        // the stall, the test reads them back-to-back with near-zero gaps and
        // passes — which is correct for "is the timer running" but does NOT
        // catch "MainActor → late delivery". A separate (likely clock-injected)
        // test would be needed to assert end-to-end latency.
        let cadence: Duration = .milliseconds(100)
        let agent = makeAgent(agentFd: agentFd, heartbeatInterval: cadence)
        defer { agent.stop() }
        agent.start()

        // First frame is the agent Hello — discard.
        _ = try await nextFrame(from: host)

        var stamps: [ContinuousClock.Instant] = []
        while stamps.count < 3 {
            // Use the shared 5 s default. If the timer is genuinely broken
            // we'll still fail in bounded time (≤15 s); if it's just slow,
            // returning the frame lets the maxGap assertion below produce a
            // sharper "cadence drift" error than a generic timeout.
            let frame = try await nextFrame(from: host)
            if case .heartbeat = frame.payload {
                stamps.append(.now)
            }
        }

        // Loop above guarantees stamps.count == 3, so gaps has exactly 2
        // elements and reduce(.zero, max) is the natural non-optional form.
        let gaps = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        let maxGap = gaps.reduce(.zero, max)
        // 10× cadence tolerance: catches "timer not running" / "cadence
        // misconfigured" without flagging single-tick scheduling jitter.
        let tolerance = cadence * 10
        #expect(
            maxGap < tolerance,
            "Heartbeat cadence drift: max gap \(maxGap) exceeds \(tolerance) (10× cadence). Gaps: \(gaps)"
        )
    }

    // MARK: - Inbound

    @Test("Inbound host Hello and Heartbeat are accepted without crashing")
    func inboundFramesAccepted() async throws {
        let (agentFd, hostFd) = try makeRawSocketPair()
        let host = VsockChannel(fileDescriptor: hostFd)
        host.start()
        defer { host.close() }

        // Wider heartbeat cadence (100 ms) + final-read timeout (800 ms) for
        // the same CI-jitter reason as `heartbeatOutboundCadence`.
        let agent = makeAgent(agentFd: agentFd, heartbeatInterval: .milliseconds(100))
        defer { agent.stop() }
        agent.start()

        // Discard agent's outbound Hello.
        _ = try await nextFrame(from: host)

        // Send host Hello + a few heartbeats. Behaviorally we just verify the
        // agent stays connected (its outbound heartbeat stream keeps flowing).
        try host.send(makeHostHelloFrame())
        for n in 1...3 {
            try host.send(makeHeartbeatFrame(nonce: UInt64(n)))
            try await Task.sleep(for: .milliseconds(50))
        }

        // The agent should still be sending heartbeats: read the next frame
        // and expect either a heartbeat or — at worst — a successful round
        // trip without a thrown error.
        let frame = try await nextFrame(from: host)
        switch frame.payload {
        case .heartbeat:
            break
        default:
            throw TestFailure(
                "Expected heartbeat from agent after inbound traffic; got \(String(describing: frame.payload))")
        }
    }

    // MARK: - UI state seam

    @Test("connectionState is .connected after connect; Hello records the host's bundled version")
    func connectionStateAndBundledVersion() async throws {
        let (agentFd, hostFd) = try makeRawSocketPair()
        let host = VsockChannel(fileDescriptor: hostFd)
        host.start()
        defer { host.close() }

        let agent = makeAgent(agentFd: agentFd, heartbeatInterval: .milliseconds(100))
        defer { agent.stop() }
        agent.start()

        // Once the agent's outbound Hello has been sent, serve() has already
        // marked the channel connected.
        _ = try await nextFrame(from: host)
        #expect(agent.connectionState == .connected)
        // No Hello received yet → host bundled version still unknown (empty).
        #expect(agent.hostBundledAgentVersion == "")

        try host.send(makeHostHelloFrame(bundledAgentVersion: "9.9.9"))
        try await waitUntil { agent.hostBundledAgentVersion == "9.9.9" }
        #expect(agent.connectionState == .connected)
    }

    @Test("connectionState reports .unresponsive after the host goes silent")
    func connectionStateUnresponsive() async throws {
        let (agentFd, hostFd) = try makeRawSocketPair()
        let host = VsockChannel(fileDescriptor: hostFd)
        host.start()
        defer { host.close() }

        // Short unresponsive window, long terminate window: the watchdog flags
        // "unresponsive" without tearing the channel down during the test.
        let states = StateBox()
        let agent = makeAgent(
            agentFd: agentFd,
            heartbeatInterval: .milliseconds(50),
            unresponsiveAfter: .milliseconds(150),
            terminateAfter: .seconds(3_600),
            onStateChange: { states.record($0) })
        defer { agent.stop() }
        agent.start()

        _ = try await nextFrame(from: host)
        // Host stays silent (sends nothing): liveness needs a first inbound frame
        // to start its clock, so send one Hello, then go quiet.
        try host.send(makeHostHelloFrame())
        try await states.changed.wait { states.value == .unresponsive }
    }

    // MARK: - Liveness teardown + reconnect

    @Test("Silent host past terminateAfter closes the channel; client reconnects with a fresh Hello")
    func unresponsiveHostTriggersReconnect() async throws {
        let (agentFd0, hostFd0) = try makeRawSocketPair()
        let (agentFd1, hostFd1) = try makeRawSocketPair()

        // Close the first host fd immediately so any agent send to host0
        // doesn't stall the test on a kernel buffer; the agent's liveness
        // watchdog tears down its own end after `terminateAfter` of silence.
        // RATIONALE: We're testing the agent's behavior on a silent host —
        // closing host0 simulates an unresponsive peer cleanly, but the
        // critical path is the watchdog timeout, not the EOF.
        close(hostFd0)

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
            guard let fd = fdBox.fd(at: n - 1) else {
                return .failure(.transient("test: no fd at index \(n - 1)"))
            }
            return .success(fd)
        }

        let agent = VsockGuestControlAgent(
            client: client,
            heartbeatInterval: .milliseconds(100),
            unresponsiveAfter: .milliseconds(200),
            terminateAfter: .milliseconds(500)
        )
        defer { agent.stop() }
        agent.start()

        // The first connection has a closed peer. The agent's heartbeat-send
        // failures plus the liveness watchdog will tear down the channel.
        // The client then reconnects with the second fd. Wait for the agent's
        // Hello on host1 — proof the reconnect cycle ran end to end.
        let firstFrame = try await nextFrame(from: host1)
        guard case .hello(let hello) = firstFrame.payload else {
            throw TestFailure("Expected Hello on reconnect, got \(String(describing: firstFrame.payload))")
        }
        #expect(hello.capabilities.contains("control.v1"))
        #expect(provideCount.value >= 2)
    }

    // MARK: - Lifecycle

    // MARK: - PolicyUpdate routing

    /// Lock-protected box for the most recent policy received via the
    /// onPolicy callback.
    private final class PolicyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: Kernova_V1_PolicyUpdate?
        /// Fires on every `set`; await it instead of polling `value`.
        let changed = AsyncGate()
        func set(_ p: Kernova_V1_PolicyUpdate) {
            lock.withLock { storedValue = p }
            changed.notify()
        }
        var value: Kernova_V1_PolicyUpdate? { lock.withLock { storedValue } }
    }

    /// Lock-protected box recording the latest connection state delivered via
    /// the agent's `onStateChange` callback.
    private final class StateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: HostConnectionState?
        /// Fires on every `record`; await it instead of polling `value`.
        let changed = AsyncGate()
        func record(_ s: HostConnectionState) {
            lock.withLock { storedValue = s }
            changed.notify()
        }
        var value: HostConnectionState? { lock.withLock { storedValue } }
    }

    @Test("Inbound PolicyUpdate is forwarded to the onPolicy callback")
    func policyUpdateRoutesToCallback() async throws {
        let (agentFd, hostFd) = try makeRawSocketPair()
        let host = VsockChannel(fileDescriptor: hostFd)
        host.start()
        defer { host.close() }

        let received = PolicyBox()
        let agent = makeAgent(
            agentFd: agentFd,
            onPolicy: { policy in
                received.set(policy)
            })
        agent.start()
        defer { agent.stop() }

        // Drain the agent's outbound Hello so subsequent reads are aligned.
        _ = try await nextFrame(from: host)

        // Send a PolicyUpdate from the host side and verify the callback fires
        // with the supplied values.
        var frame = Frame()
        frame.protocolVersion = 1
        frame.policyUpdate = Kernova_V1_PolicyUpdate.with {
            $0.logForwardingEnabled = true
            $0.clipboardSharingEnabled = false
        }
        try host.send(frame)

        try await received.changed.wait { received.value != nil }
        let policy = try #require(received.value)
        #expect(policy.logForwardingEnabled == true)
        #expect(policy.clipboardSharingEnabled == false)
    }

    @Test("Multiple PolicyUpdate frames each invoke the callback")
    func multiplePolicyUpdatesRouteToCallback() async throws {
        let (agentFd, hostFd) = try makeRawSocketPair()
        let host = VsockChannel(fileDescriptor: hostFd)
        host.start()
        defer { host.close() }

        let counts = AtomicInt()
        let agent = makeAgent(
            agentFd: agentFd,
            onPolicy: { _ in
                _ = counts.increment()
            })
        agent.start()
        defer { agent.stop() }

        _ = try await nextFrame(from: host)  // drain outbound Hello

        for _ in 0..<3 {
            var frame = Frame()
            frame.protocolVersion = 1
            frame.policyUpdate = Kernova_V1_PolicyUpdate.with {
                $0.logForwardingEnabled = true
                $0.clipboardSharingEnabled = true
            }
            try host.send(frame)
        }

        try await counts.changed.wait { counts.value >= 3 }
    }

    @Test("clipboard enable is forwarded only when the host advertised streaming")
    func clipboardGatedOnHostCapability() async throws {
        let (agentFd, hostFd) = try makeRawSocketPair()
        let host = VsockChannel(fileDescriptor: hostFd)
        host.start()
        defer { host.close() }

        let received = PolicyBox()
        let agent = makeAgent(
            agentFd: agentFd,
            onPolicy: { policy in received.set(policy) })
        agent.start()
        defer { agent.stop() }

        _ = try await nextFrame(from: host)  // drain outbound Hello

        // Host that doesn't speak streaming, then a clipboard-enable policy.
        try host.send(makeHostHelloFrame(streamingCapable: false))
        var frame = Frame()
        frame.protocolVersion = 1
        frame.policyUpdate = Kernova_V1_PolicyUpdate.with {
            $0.logForwardingEnabled = true
            $0.clipboardSharingEnabled = true
        }
        try host.send(frame)

        try await received.changed.wait { received.value != nil }
        let policy = try #require(received.value)
        // Log forwarding passes through; clipboard is forced off by the gate.
        #expect(policy.logForwardingEnabled == true)
        #expect(policy.clipboardSharingEnabled == false)
    }

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
