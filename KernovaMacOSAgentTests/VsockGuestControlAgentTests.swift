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
    private static let testHeartbeat: TimeInterval = 0.04

    /// Default liveness windows, set far beyond any test's wall-clock budget.
    ///
    /// The watchdog can't tear the channel down mid-test at these values. Tests
    /// that *exercise* the watchdog pass explicit short windows to opt back in.
    ///
    /// The watchdog measures elapsed time since `lastInboundFrame`, which
    /// keeps advancing while a contended CI MainActor stalls the test. With a
    /// short default, any non-watchdog test that paused past the window saw the
    /// channel closed out from under it — surfacing as an EOF / `.closed` flake.
    /// Making the watchdog an explicit opt-in removes that coupling. Mirrors
    /// `VsockControlServiceTests` / `makeService`. See docs/TESTING.md "Async waits in tests".
    private static let watchdogDisabledUnresponsive: TimeInterval = 3_600
    private static let watchdogDisabledTerminate: TimeInterval = 7_200

    /// Builds a single-fd-shot agent with the liveness watchdog disabled by
    /// default.
    ///
    /// The agent's
    /// `client` provider hands `agentFd` on the first call, transient failure
    /// after — so reconnect tests must use a multi-fd provider explicitly.
    private func makeAgent(
        clock: any EngineClock = MonotonicEngineClock(),
        agentFd: Int32,
        heartbeatInterval: TimeInterval? = nil,
        unresponsiveAfter: TimeInterval? = nil,
        terminateAfter: TimeInterval? = nil,
        onPolicy: (@Sendable (Kernova_V1_PolicyUpdate) -> Void)? = nil,
        onStateChange: (@Sendable (HostConnectionState) -> Void)? = nil,
        onHostCapabilitiesChanged: (@Sendable () -> Void)? = nil
    ) -> VsockGuestControlAgent {
        let provided = AtomicInt()
        let provider: VsockSocketProvider = { _, _ in
            provided.increment() == 1 ? .success(agentFd) : .failure(.transient("test: no fd"))
        }
        return VsockGuestControlAgent(
            clock: clock,
            client: VsockGuestClient(
                port: KernovaVsockPort.control,
                label: "control-test",
                clock: clock,
                retryInterval: 60,
                socketProvider: provider),
            heartbeatInterval: heartbeatInterval ?? Self.testHeartbeat,
            unresponsiveAfter: unresponsiveAfter ?? Self.watchdogDisabledUnresponsive,
            terminateAfter: terminateAfter ?? Self.watchdogDisabledTerminate,
            onPolicy: onPolicy,
            onStateChange: onStateChange,
            onHostCapabilitiesChanged: onHostCapabilitiesChanged
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
        #expect(hello.capabilities.contains(KernovaCapability.clipboardTransferV3))
    }

    @Test("Guest Hello reports agent_info with a numeric os_version")
    func guestHelloReportsNumericOSVersion() async throws {
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
        #expect(hello.agentInfo.os == "macOS")
        #expect(hello.agentInfo.osVersion == KernovaOSVersion.current)
        // The numeric shape is the documented wire contract, so a localized
        // `Version 26.0 (Build 25A123)` — or its translation in a non-English
        // guest — must never reach the wire.
        #expect(hello.agentInfo.osVersion.allSatisfy { $0.isNumber || $0 == "." })
    }

    // MARK: - Heartbeat

    @Test("Every outbound heartbeat costs one sleep of the configured interval")
    func outboundHeartbeatSleepsTheConfiguredInterval() async throws {
        let (agentFd, hostFd) = try makeRawSocketPair()
        let host = VsockChannel(fileDescriptor: hostFd)
        host.start()
        defer { host.close() }

        // The recorder owns the host's inbound stream for the whole test:
        // `nextFrame` would consume from the same single-consumer stream.
        let recorder = FrameRecorder(channel: host)
        defer { recorder.cancel() }

        // Production-scale windows, because the clock below never advances on
        // its own: the heartbeat loop moves one step per release, and the
        // liveness loop stays parked on its very first tick, so neither
        // watchdog stage can fire while the test asserts. `unresponsiveAfter`
        // is picked so the derived liveness tick differs from the heartbeat
        // interval, which is what tells the two parked sleeps apart.
        let heartbeatSeconds: TimeInterval = 5
        let clock = GatedEngineClock()
        let agent = makeAgent(
            clock: clock,
            agentFd: agentFd,
            heartbeatInterval: heartbeatSeconds,
            unresponsiveAfter: 9,
            terminateAfter: 30)
        defer { agent.stop() }
        agent.start()

        // Both timer loops park on their first sleep; reaching that point is
        // also proof the channel is up, since `serve` is what starts them.
        //
        // The property under test: the heartbeat loop asked for exactly the
        // configured interval — not a hardcoded constant, not a multiple, and
        // not zero.
        try await clock.sleepRequested.wait { clock.parked.count >= 2 }
        #expect(
            clock.parked.filter { $0.seconds == heartbeatSeconds }.count == 1,
            "Expected exactly one parked sleep of \(heartbeatSeconds) s; parked: \(clock.parked.map(\.seconds))"
        )

        for round in 1...3 {
            let sleeper = try #require(clock.parked.first { $0.seconds == heartbeatSeconds })
            clock.release(sleeper)
            try await recorder.waitForFrames { recorder.heartbeats.count == round }
            // The loop parks again on the same interval before it can send
            // anything else, so the next heartbeat costs another full interval.
            try await clock.sleepRequested.wait {
                clock.requestedSeconds.filter { $0 == heartbeatSeconds }.count == round + 1
            }
            #expect(recorder.heartbeats.count == round)
            // Nonces number the sends, so a repeat would show a duplicate here.
            #expect(recorder.heartbeats.map(\.nonce) == Array(1...UInt64(round)))
        }
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
        let agent = makeAgent(agentFd: agentFd, heartbeatInterval: 0.1)
        defer { agent.stop() }
        agent.start()

        // Discard agent's outbound Hello.
        _ = try await nextFrame(from: host)

        // Send host Hello + a few heartbeats. Behaviorally we just verify the
        // agent stays connected (its outbound heartbeat stream keeps flowing).
        try host.send(makeHostHelloFrame())
        for n in 1...3 {
            try host.send(makeHeartbeatFrame(nonce: UInt64(n)))
            try await Task.sleep(nanoseconds: 50_000_000)
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

        let notified = AtomicInt()
        let agent = makeAgent(
            agentFd: agentFd,
            heartbeatInterval: 0.1,
            onHostCapabilitiesChanged: { notified.increment() })
        defer { agent.stop() }
        agent.start()

        // Once the agent's outbound Hello has been sent, serve() has already
        // marked the channel connected.
        _ = try await nextFrame(from: host)
        // The connection itself clears the previous host's capabilities.
        try await notified.changed.wait { notified.value >= 1 }
        #expect(agent.connectionState == .connected)
        // No Hello received yet → host bundled version still unknown (empty).
        #expect(agent.hostBundledAgentVersion == "")

        try host.send(makeHostHelloFrame(bundledAgentVersion: "9.9.9"))
        try await notified.changed.wait { notified.value >= 2 }
        #expect(agent.hostBundledAgentVersion == "9.9.9")
        #expect(agent.connectionState == .connected)
    }

    @Test(
        "connectionState reports .unresponsive after the host goes silent",
        arguments: EngineClockKind.allCases)
    func connectionStateUnresponsive(kind: EngineClockKind) async throws {
        let (agentFd, hostFd) = try makeRawSocketPair()
        let host = VsockChannel(fileDescriptor: hostFd)
        host.start()
        defer { host.close() }

        // Short unresponsive window; terminate stays disabled (the makeAgent
        // default), so the watchdog flags "unresponsive" without tearing the
        // channel down during the test.
        let states = StateBox()
        let agent = makeAgent(
            clock: kind.makeClock(),
            agentFd: agentFd,
            heartbeatInterval: 0.05,
            unresponsiveAfter: 0.15,
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

    @Test(
        "Silent host past terminateAfter closes the channel; client reconnects with a fresh Hello",
        arguments: EngineClockKind.allCases)
    func unresponsiveHostTriggersReconnect(kind: EngineClockKind) async throws {
        let (agentFd0, hostFd0) = try makeRawSocketPair()
        let (agentFd1, hostFd1) = try makeRawSocketPair()

        // Close the first host fd immediately so any agent send to host0
        // doesn't stall the test on a kernel buffer; the agent's liveness
        // watchdog tears down its own end after `terminateAfter` of silence —
        // the watchdog timeout, not the EOF, is the path under test.
        close(hostFd0)

        let host1 = VsockChannel(fileDescriptor: hostFd1)
        host1.start()
        defer { host1.close() }

        let fdBox = FdBox(fds: [agentFd0, agentFd1])
        let provideCount = AtomicInt()

        let provider: VsockSocketProvider = { _, _ in
            let n = provideCount.increment()
            guard let fd = fdBox.fd(at: n - 1) else {
                return .failure(.transient("test: no fd at index \(n - 1)"))
            }
            return .success(fd)
        }

        let clock = kind.makeClock()
        let agent = VsockGuestControlAgent(
            clock: clock,
            client: VsockGuestClient(
                port: KernovaVsockPort.control,
                label: "control-reconnect-test",
                clock: clock,
                retryInterval: 0.05,
                socketProvider: provider),
            heartbeatInterval: 0.1,
            unresponsiveAfter: 0.2,
            terminateAfter: 0.5
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

    // MARK: - Display drops

    @Test("the host's drop capability is recorded from its Hello")
    func hostDropCapabilityObservedFromHello() async throws {
        let (agentFd, hostFd) = try makeRawSocketPair()
        let host = VsockChannel(fileDescriptor: hostFd)
        host.start()
        defer { host.close() }

        let notified = AtomicInt()
        let agent = makeAgent(agentFd: agentFd, onHostCapabilitiesChanged: { notified.increment() })
        agent.start()
        defer { agent.stop() }

        _ = try await nextFrame(from: host)  // drain outbound Hello
        // The connection itself clears the previous host's capabilities, which
        // is a change the drop client has to hear about too.
        try await notified.changed.wait { notified.value >= 1 }
        #expect(agent.hostSupportsDropFiles == false)

        try host.send(makeHostHelloFrame())
        try await notified.changed.wait { notified.value >= 2 }
        #expect(agent.hostSupportsDropFiles)
    }

    @Test("a host that advertises no drop capability leaves it off")
    func hostWithoutDropCapability() async throws {
        let (agentFd, hostFd) = try makeRawSocketPair()
        let host = VsockChannel(fileDescriptor: hostFd)
        host.start()
        defer { host.close() }

        let notified = AtomicInt()
        let agent = makeAgent(agentFd: agentFd, onHostCapabilitiesChanged: { notified.increment() })
        agent.start()
        defer { agent.stop() }

        _ = try await nextFrame(from: host)  // drain outbound Hello
        try host.send(makeHostHelloFrame(streamingCapable: false))
        try await notified.changed.wait { notified.value >= 2 }

        #expect(agent.hostSupportsDropFiles == false)
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
