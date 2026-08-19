import Testing
import Foundation
import Darwin
import KernovaKit
import KernovaTestSupport
@testable import Kernova

@Suite("VsockControlService")
@MainActor
struct VsockControlServiceTests {
    // MARK: - Helpers

    private func makePair() throws -> (sender: VsockChannel, receiver: VsockChannel) {
        let (a, b) = try makeRawSocketPair()
        return (VsockChannel(fileDescriptor: a), VsockChannel(fileDescriptor: b))
    }

    /// Builds a guest-side Hello frame with the given agent version.
    ///
    /// Tests use
    /// this to drive the `agentStatus` numeric-comparison matrix.
    private func makeGuestHello(
        agentVersion: String, osVersion: String = "26.0", streamingCapable: Bool = true
    ) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            var capabilities = [KernovaCapability.controlV1, KernovaCapability.controlHeartbeatV1]
            if streamingCapable { capabilities.append(KernovaCapability.clipboardTransferV3) }
            $0.capabilities = capabilities
            $0.agentInfo = Kernova_V1_AgentInfo.with {
                $0.os = "macOS"
                $0.osVersion = osVersion
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

    /// Default outbound-heartbeat cadence: small, and harmless to every test
    /// (extra heartbeats only keep the connection alive).
    private static let testHeartbeat: TimeInterval = 0.04

    /// Starts a background task sending guest heartbeats every `interval`,
    /// until cancelled (callers pair it with a `defer { task.cancel() }`).
    ///
    /// A live guest sends heartbeats continuously, so liveness tests emit a
    /// sustained stream rather than a fixed batch: status changes are driven by
    /// a liveness tick observing a fresh `lastInboundFrame`, and that clock is
    /// refreshed *only* by inbound frames. If the stream stopped before the
    /// test's final wait resolved, a tick starved past `unresponsiveAfter`
    /// would latch `.unresponsive` with no further inbound frames to recover
    /// it, and the test would hang to its backstop. (The heartbeat nonce is
    /// ignored by the service — liveness keys only off the frame arriving — so
    /// the default nonce is fine.)
    private func sustainHeartbeats(
        on guest: VsockChannel, every interval: Duration
    ) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? guest.send(makeHeartbeat())
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Default liveness windows, set far beyond any test's wall-clock budget.
    ///
    /// The watchdog can't tear the channel down mid-test at these values. Tests
    /// that *exercise* the watchdog (silence/recovery/terminate) pass explicit
    /// short windows to opt back in.
    ///
    /// The watchdog measures elapsed time since `lastInboundFrame`, which
    /// keeps advancing while a contended CI MainActor stalls the test: a
    /// sub-second window makes every test's runtime an implicit deadline, so a
    /// test that pauses past it (waiting on a frame, a `waitUntil`, or scheduler
    /// jitter) sees the channel closed out from under it as an EOF / `.closed`
    /// flake. These values make the watchdog an explicit opt-in instead. See
    /// docs/TESTING.md "Async waits in tests".
    private static let watchdogDisabledUnresponsive: TimeInterval = 3_600
    private static let watchdogDisabledTerminate: TimeInterval = 7_200

    /// Builds a service with the test cadences applied.
    ///
    /// Caller decides
    /// `bundledAgentVersion`. The service is NOT started — caller invokes
    /// `start()` after wiring the recorder.
    private func makeService(
        channel: VsockChannel,
        bundledAgentVersion: String? = "0.9.0",
        clock: any EngineClock = makePlatformEngineClock(),
        heartbeatInterval: TimeInterval? = nil,
        unresponsiveAfter: TimeInterval? = nil,
        terminateAfter: TimeInterval? = nil,
        policyProvider: (@MainActor () -> AgentPolicySnapshot)? = nil,
        onAgentInfoObserved: (@MainActor (ObservedAgentInfo) -> Void)? = nil,
        isGuestSuspended: (@MainActor () -> Bool)? = nil,
        onChannelLost: (@MainActor () -> Void)? = nil
    ) -> VsockControlService {
        VsockControlService(
            channel: channel,
            label: "test",
            bundledAgentVersion: bundledAgentVersion,
            clock: clock,
            heartbeatInterval: heartbeatInterval ?? Self.testHeartbeat,
            unresponsiveAfter: unresponsiveAfter ?? Self.watchdogDisabledUnresponsive,
            terminateAfter: terminateAfter ?? Self.watchdogDisabledTerminate,
            policyProvider: policyProvider,
            onAgentInfoObserved: onAgentInfoObserved,
            isGuestSuspended: isGuestSuspended,
            onChannelLost: onChannelLost
        )
    }

    /// Completes the handshake for a test that arms a sub-second
    /// `terminateAfter`, latching the Hello instead of observing `isConnected`.
    ///
    /// Those tests cannot wait on `isConnected`: it is a transient the watchdog
    /// reverts. The watchdog measures elapsed time since `lastInboundFrame`,
    /// so a MainActor stall longer than the window leaves the next liveness tick
    /// already past its deadline — and if that tick runs before the waiter's
    /// continuation, the service settles `isConnected` back to `false` before
    /// the waiter ever sees it. Nothing changes it again, so the waiter blocks
    /// to its backstop and fails a service that connected exactly as asked.
    /// `onAgentInfoObserved` fires inside the same MainActor turn that sets
    /// `isConnected`, and the recorder only ever counts up, so a stall of any
    /// length delays this wait rather than losing it.
    private func connectLatched(
        guest: VsockChannel, hello: ObservedRecorder, agentVersion: String = "0.9.0"
    ) async throws {
        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(agentVersion: agentVersion))
        try await hello.changed.wait { !hello.values.isEmpty }
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
        // The host advertises streaming-clipboard support so the guest can
        // symmetrically gate clipboard on it.
        #expect(hello.capabilities.contains(KernovaCapability.clipboardTransferV3))
    }

    @Test("Host Hello reports agent_info with a numeric os_version")
    func hostHelloReportsNumericOSVersion() async throws {
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
        #expect(hello.agentInfo.os == "macOS")
        #expect(hello.agentInfo.osVersion == KernovaOSVersion.current)
        #expect(hello.agentInfo.osVersion.allSatisfy { $0.isNumber || $0 == "." })
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

        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))

        try await waitForChange { service.isConnected }
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
        try await waitForChange { service.isConnected }

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
        try await waitForChange { service.isConnected }

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
        try await waitForChange { service.isConnected }

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
        try await waitForChange { service.isConnected }

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
        try await waitForChange { service.isConnected }

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
        try await waitForChange { service.isConnected }
        #expect(service.agentStatus == .current(version: "0.9.0"))

        service.stop()
        #expect(service.agentStatus == .waiting)
    }

    // MARK: - Heartbeat

    @Test("Every outbound heartbeat costs one sleep of the configured interval")
    func outboundHeartbeatSleepsTheConfiguredInterval() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // The recorder owns the guest's inbound stream for the whole test:
        // `nextFrame` would consume from the same single-consumer stream.
        let recorder = FrameRecorder(channel: guest)
        defer { recorder.cancel() }

        // Production-scale windows, because the clock below never advances on
        // its own: the heartbeat loop moves one step per release, and the
        // liveness loop stays parked on its very first tick, so neither
        // watchdog stage can fire while the test asserts. `unresponsiveAfter`
        // is picked so the derived liveness tick differs from the heartbeat
        // interval, which is what tells the two parked sleeps apart.
        let heartbeatSeconds: TimeInterval = 5
        let clock = GatedEngineClock()
        let service = makeService(
            channel: host,
            clock: clock,
            heartbeatInterval: heartbeatSeconds,
            unresponsiveAfter: 9,
            terminateAfter: 30)
        service.start()
        defer { service.stop() }

        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }

        // Both timer loops park on their first sleep. The property under test:
        // the heartbeat loop asked for exactly the configured interval — not a
        // hardcoded constant, not a multiple, and not zero.
        try await clock.sleepRequested.wait { clock.parked.count >= 2 }
        // `#require`, not `#expect`: every release below picks its sleeper by
        // this interval, so a failure here leaves the loop waiting on a sleep
        // nothing will ever match — a backstop hang in place of this message.
        try #require(
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
        // just sent a heartbeat. The watchdog's terminate stage stays disabled
        // (the makeService default): it is not under test, and a multi-second
        // stall in the sender loop once let a finite 5 s `terminateAfter` close
        // the channel out from under the test — the send then threw `.closed`.
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            heartbeatInterval: 0.2,
            unresponsiveAfter: 0.4
        )
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }

        // Sustained heartbeats every 100 ms (well below the 400 ms unresponsive
        // window), kept running through the assertion below so a jitter-induced
        // transient `.unresponsive` flip can recover (see `sustainHeartbeats`).
        let sustainedHeartbeats = sustainHeartbeats(on: guest, every: .milliseconds(100))
        defer { sustainedHeartbeats.cancel() }

        // Let a window > 2× unresponsiveAfter elapse, then assert end-state. If
        // heartbeats had not been resetting the inbound-liveness clock, status
        // would be (and stay) .unresponsive — the wait would hit its backstop.
        // The event-driven wait absorbs a starved-scheduler transient flip: the
        // continuing heartbeats recover it, and the observation wakes the wait.
        try await Task.sleep(for: .milliseconds(800))
        try await waitForChange { service.agentStatus == .current(version: "0.9.0") }
    }

    @Test("Silence past unresponsiveAfter flips agentStatus to .unresponsive")
    func silenceMarksUnresponsive() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // Terminate stays disabled (the makeService default): it is not under
        // test here, and with the old finite 2 s value a starved scheduler
        // could delay the first liveness tick past `terminateAfter`, so that
        // tick closed the channel *without ever latching `.unresponsive`* —
        // the waited condition then could never become true (see checkLiveness:
        // the terminate branch skips the unresponsive latch).
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            heartbeatInterval: 0.06,
            unresponsiveAfter: 0.1
        )
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }

        // Don't send any further inbound. After ~100ms+ the watchdog flips.
        try await waitForChange {
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

        // Terminate stays disabled (the makeService default): it is not under
        // test, and any finite value races the test body — on slow runners the
        // original 2 s fired between detecting `.unresponsive` and recovery,
        // leaving the service stuck.
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            heartbeatInterval: 0.06,
            unresponsiveAfter: 0.1
        )
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }

        // Go silent → unresponsive.
        try await waitForChange {
            service.agentStatus == .unresponsive(version: "0.9.0")
        }

        // Resume heartbeats as a sustained stream, not a single frame — a lone
        // heartbeat opens just one ~unresponsiveAfter-wide recovery window a
        // starved tick can miss (see `sustainHeartbeats`).
        let resumeHeartbeats = sustainHeartbeats(on: guest, every: .milliseconds(60))
        defer { resumeHeartbeats.cancel() }

        // The recovery → .current transition was the original CI flake (the poll
        // budget timed out under jitter). This suite's agentStatus/isConnected
        // waits are all event-driven now; see docs/TESTING.md "Async waits in tests".
        try await waitForChange {
            service.agentStatus == .current(version: "0.9.0")
        }
        #expect(service.agentStatus == .current(version: "0.9.0"))
    }

    @Test("Silence past terminateAfter settles the service and stops the watchdog")
    func terminateSettlesTheService() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // Widen cadences for CI runner jitter (the original 40/80/200 ms
        // pairing was tight enough that on slow runners the watchdog could
        // miss its window before the terminate condition fired).
        let helloObserved = ObservedRecorder()
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            heartbeatInterval: 0.1,
            unresponsiveAfter: 0.2,
            terminateAfter: 0.5,
            onAgentInfoObserved: { helloObserved.append($0) }
        )

        service.start()
        defer { service.stop() }

        // Captured now: the teardown clears the handles.
        let lifecycleTasks = service.lifecycleTasksForTesting

        try await connectLatched(guest: guest, hello: helloObserved)

        // Send nothing further: the watchdog terminates the connection. The
        // service has to settle rather than re-fire every tick against a frozen
        // `lastInboundFrame`.
        try await waitForChange { !service.isConnected }

        // Every periodic task runs to completion — no watchdog tick and no
        // heartbeat send survives the teardown.
        for task in lifecycleTasks {
            await task.value
        }
        #expect(service.lifecycleTasksForTesting.isEmpty)
        #expect(service.agentVersion == nil)
        #expect(service.agentStatus == .waiting)
        // The channel went with it: the teardown closes before clearing
        // `isConnected`, so this is ordered, not racy.
        #expect(throws: VsockChannelError.closed) { try host.send(makeHeartbeat()) }
    }

    @Test("A channel closed by the peer settles the service")
    func consumeEndSettlesTheService() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // Watchdog disabled (the makeService default), so only the consume
        // path can settle this one.
        let service = makeService(channel: host, bundledAgentVersion: "0.9.0")
        service.start()
        defer { service.stop() }

        let lifecycleTasks = service.lifecycleTasksForTesting

        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }

        // The guest agent goes away: EOF unwinds the consume loop, and nobody
        // calls stop() on the host side until the *next* accept.
        guest.close()

        try await waitForChange { !service.isConnected }
        for task in lifecycleTasks {
            await task.value
        }
        #expect(service.agentVersion == nil)
        #expect(service.agentStatus == .waiting)

        // Settle-then-explicit-stop: the owner still tears down normally.
        service.stop()
        #expect(!service.isConnected)
    }

    @Test("A settled service is terminal — start() does not resurrect it")
    func settledServiceStaysDown() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = makeService(channel: host, bundledAgentVersion: "0.9.0")
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }

        guest.close()
        try await waitForChange { !service.isConnected }

        // A reconnect is served by a fresh instance built at accept time, so
        // restarting this one would only spin tasks against a dead socket.
        service.start()
        #expect(!service.isConnected)
        #expect(service.lifecycleTasksForTesting.isEmpty)
    }

    // MARK: - Live-paused guest

    @Test("A suspended guest is never judged silent, however long the pause runs")
    func suspendedGuestSurvivesTerminateWindow() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // A live-paused VM is frozen by design: the guest cannot answer a
        // heartbeat, so the pre-#706 behavior — terminate for silence — blamed
        // the agent for the user's pause.
        let suspension = SuspensionFlag()
        let helloObserved = ObservedRecorder()
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            heartbeatInterval: 0.05,
            unresponsiveAfter: 0.1,
            terminateAfter: 0.2,
            onAgentInfoObserved: { helloObserved.append($0) },
            isGuestSuspended: { suspension.isSuspended }
        )
        service.start()
        defer { service.stop() }

        // Suspended before the Hello, not after it: the watchdog starts judging
        // the guest the instant `lastInboundFrame` is set, so any gap between
        // connect and the flip is a window where a stalled runner terminates
        // the channel for the very pause under test. Armed up front there is no
        // such window — every tick that can read the clock reads it suspended —
        // which is what makes these sub-second windows stall-proof.
        suspension.isSuspended = true
        try await connectLatched(guest: guest, hello: helloObserved)

        // RATIONALE: negative assertion ("prove the watchdog never fired") —
        // a fixed observation window, per docs/TESTING.md "Async waits in tests".
        // Four terminate windows with the guest sending nothing at all.
        try await Task.sleep(for: .milliseconds(800))
        #expect(service.isConnected)
        #expect(service.agentStatus == .current(version: "0.9.0"))
    }

    @Test("Suspension defers the liveness deadline rather than disabling it")
    func resumedGuestGetsAFreshWindow() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let suspension = SuspensionFlag()
        let helloObserved = ObservedRecorder()
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            heartbeatInterval: 0.05,
            unresponsiveAfter: 0.1,
            terminateAfter: 0.2,
            onAgentInfoObserved: { helloObserved.append($0) },
            isGuestSuspended: { suspension.isSuspended }
        )
        service.start()
        defer { service.stop() }

        // Suspended before the Hello — see
        // `suspendedGuestSurvivesTerminateWindow` for why the flip cannot
        // trail the connect.
        suspension.isSuspended = true
        try await connectLatched(guest: guest, hello: helloObserved)

        // RATIONALE: negative assertion ("prove the watchdog didn't fire during
        // the pause") — a fixed observation window, per docs/TESTING.md "Async
        // waits in tests". Three terminate windows, guest sending nothing.
        try await Task.sleep(for: .milliseconds(600))
        #expect(service.isConnected)

        // Resuming hands the guest a window it can still miss: nothing has been
        // heard from it, so the deadline starts running again and expires.
        suspension.isSuspended = false
        try await waitForChange { !service.isConnected }
        #expect(service.agentStatus == .waiting)
    }

    @Test("No heartbeat is written to a suspended guest")
    func noHeartbeatWhileSuspended() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // `VsockChannel.writeFramed` parks in a blocking `write(2)` once the
        // peer's receive buffer fills, on the main actor — and a frozen guest
        // drains nothing. Sending to one is a main-thread hang waiting to
        // happen, so nothing may go out.
        //
        // The recorder owns the guest's inbound stream for the whole test:
        // `nextFrame` would consume from the same single-consumer stream and
        // race it for frames.
        let recorder = FrameRecorder(channel: guest)
        defer { recorder.cancel() }

        let suspension = SuspensionFlag()
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            heartbeatInterval: 0.05,
            isGuestSuspended: { suspension.isSuspended }
        )
        service.start()
        defer { service.stop() }

        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }
        // Prove the sender is genuinely running before freezing it, so a
        // silent-for-another-reason service can't pass this test.
        try await recorder.waitForFrameCount(2)

        // Snapshot the baseline only after a settle window: a heartbeat written
        // just before the flip is still in flight through the socket and the
        // recorder's task, and counting it against the frozen guest would be a
        // false failure.
        //
        // RATIONALE: no signal marks "the in-flight frame has landed", so the
        // settle is a fixed window like the negative assertion it precedes
        // (docs/TESTING.md "Async waits in tests").
        suspension.isSuspended = true
        try await Task.sleep(for: .milliseconds(150))

        // Spans many heartbeat intervals.
        try await recorder.expectNoNewFrames(sinceCount: recorder.count, for: 0.4)
    }

    // MARK: - onChannelLost

    @Test("onChannelLost fires when the liveness watchdog terminates a silent channel")
    func channelLostOnLivenessTerminate() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let lost = ChannelLostRecorder()
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            heartbeatInterval: 0.1,
            unresponsiveAfter: 0.2,
            terminateAfter: 0.5,
            onChannelLost: { lost.record() }
        )
        lost.sampleAgentVersion = { [weak service] in service?.agentVersion }
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)  // host hello
        // No wait on `isConnected` in between: with a terminate window this
        // short the settle can beat the observation, and the callback — not the
        // connected state — is what this test is about.
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))

        try await lost.changed.wait { lost.count == 1 }
        // The callback runs on fully-settled state, which is what lets
        // `VMInstance` re-arm its agent watchdog on a nil `agentVersion`
        // instead of no-oping against the stale one.
        #expect(lost.sampledAgentVersions == [nil])
    }

    @Test("onChannelLost fires when the peer closes the channel")
    func channelLostOnPeerClose() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()

        let lost = ChannelLostRecorder()
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            onChannelLost: { lost.record() }
        )
        lost.sampleAgentVersion = { [weak service] in service?.agentVersion }
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }

        // The guest agent quits mid-session: EOF unwinds the consume loop.
        guest.close()

        try await lost.changed.wait { lost.count == 1 }
        #expect(lost.sampledAgentVersions == [nil])
    }

    @Test("onChannelLost stays silent for an owner-requested stop()")
    func channelLostSkippedForOwnerStop() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // Session teardown and the accept path's replace-the-previous-service
        // both route here. The owner already knows, and telling it the channel
        // "died" would arm a watchdog against a VM it is shutting down.
        let lost = ChannelLostRecorder()
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            onChannelLost: { lost.record() }
        )
        service.start()

        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }

        service.stop()
        #expect(!service.isConnected)

        // RATIONALE: negative assertion ("prove the callback never fired") —
        // a fixed observation window, per docs/TESTING.md "Async waits in
        // tests". The consume task also unwinds in here, and its settle must
        // not fire the callback either: the owner's stop() latched first.
        try await Task.sleep(for: .milliseconds(200))
        #expect(lost.count == 0)
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
        try await waitForChange { service.isConnected }

        service.stop()
        #expect(!service.isConnected)
        #expect(service.agentVersion == nil)
        #expect(service.agentStatus == .waiting)

        // Second stop() is a no-op.
        service.stop()
        #expect(!service.isConnected)
    }

    // MARK: - PolicyUpdate

    @Test("Sends initial PolicyUpdate after guest Hello when policyProvider is supplied")
    func sendsInitialPolicyAfterHello() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = makeService(
            channel: host,
            policyProvider: {
                AgentPolicySnapshot(
                    logForwardingEnabled: true, clipboardSharingEnabled: false,
                    clipboardMaxPasteBytes: ClipboardPasteLimit.defaultBytes)
            }
        )
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))

        // Skip frames until we see PolicyUpdate (heartbeat may interleave).
        var policy: Kernova_V1_PolicyUpdate?
        for _ in 0..<5 where policy == nil {
            let next = try await nextFrame(from: guest)
            if case .policyUpdate(let p) = next.payload {
                policy = p
            }
        }
        let received = try #require(policy)
        #expect(received.logForwardingEnabled == true)
        #expect(received.clipboardSharingEnabled == false)
    }

    @Test("Does not send PolicyUpdate when no policyProvider is supplied")
    func skipsPolicyWhenProviderAbsent() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = makeService(channel: host)  // no policyProvider
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }

        // Read a few frames; none should be PolicyUpdate. Each read returns as
        // soon as a frame arrives (heartbeats fire every 40 ms), so the default
        // backstop only bounds a genuinely stuck stream — a CI scheduling
        // stall between heartbeats can't time out and flake the test.
        for _ in 0..<3 {
            let next = try await nextFrame(from: guest)
            if case .policyUpdate = next.payload {
                Issue.record("Unexpected PolicyUpdate when no provider was supplied")
                return
            }
        }
    }

    // MARK: - onAgentInfoObserved

    @Test("onAgentInfoObserved fires once when the guest reports a non-empty version")
    func onAgentInfoObservedFires() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let observed = ObservedRecorder()
        let service = makeService(
            channel: host,
            onAgentInfoObserved: { observed.append($0) }
        )
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(agentVersion: "0.9.2"))
        try await waitForChange { service.isConnected }

        // The Hello handler runs synchronously after the inbound frame is
        // dispatched on the main actor, so by the time isConnected flips the
        // observer has already been invoked.
        #expect(observed.values == [ObservedAgentInfo(agentVersion: "0.9.2", osVersion: "26.0")])
    }

    @Test("onAgentInfoObserved is skipped when the guest reports an empty version")
    func onAgentInfoObservedSkippedForEmpty() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let observed = ObservedRecorder()
        let service = makeService(
            channel: host,
            onAgentInfoObserved: { observed.append($0) }
        )
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)
        try guest.send(makeGuestHello(agentVersion: ""))
        try await waitForChange { service.isConnected }

        // Connection succeeds (isConnected is set unconditionally on Hello),
        // but agentVersion stays nil and the observer must not fire — the
        // host has no meaningful version to persist.
        #expect(service.agentVersion == nil)
        #expect(observed.values.isEmpty)
    }

    @Test("onAgentInfoObserved fires once per Hello (dedup is the caller's job)")
    func onAgentInfoObservedFiresPerHello() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let observed = ObservedRecorder()
        let service = makeService(
            channel: host,
            onAgentInfoObserved: { observed.append($0) }
        )
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)
        try guest.send(makeGuestHello(agentVersion: "0.9.2"))
        try await waitForChange { service.isConnected }
        try guest.send(makeGuestHello(agentVersion: "0.9.2"))

        // Service fires the closure verbatim each time. Suppressing duplicate
        // writes is `VMInstance`'s responsibility (it compares against the
        // persisted value before invoking onUpdateConfiguration).
        try await observed.changed.wait { observed.values.count == 2 }
        #expect(observed.values.map(\.agentVersion) == ["0.9.2", "0.9.2"])
    }

    @Test("The callback payload carries the reported os_version verbatim")
    func guestOSVersionCarriedVerbatim() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let observed = ObservedRecorder()
        let service = makeService(
            channel: host,
            onAgentInfoObserved: { observed.append($0) }
        )
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(agentVersion: "0.9.2", osVersion: "Version 26.0 (Build 25A123)"))
        try await waitForChange { service.isConnected }

        #expect(
            observed.values == [
                ObservedAgentInfo(
                    agentVersion: "0.9.2", osVersion: "Version 26.0 (Build 25A123)")
            ])
    }

    @Test("An empty os_version is normalized to nil in the callback payload")
    func guestOSVersionEmptyNormalizedToNil() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let observed = ObservedRecorder()
        let service = makeService(
            channel: host,
            onAgentInfoObserved: { observed.append($0) }
        )
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)
        try guest.send(makeGuestHello(agentVersion: "0.9.2", osVersion: ""))
        try await waitForChange { service.isConnected }

        // The callback still fires (the agent version is meaningful) but must
        // carry nil, not "" — the host persists the payload verbatim.
        #expect(observed.values == [ObservedAgentInfo(agentVersion: "0.9.2", osVersion: nil)])
    }

    @Test("Over-long version fields are clipped before they reach the callback")
    func oversizedAgentInfoFieldsAreBounded() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let observed = ObservedRecorder()
        let service = makeService(
            channel: host,
            onAgentInfoObserved: { observed.append($0) }
        )
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)  // host hello
        let flood = String(repeating: "9", count: 4096)
        try guest.send(makeGuestHello(agentVersion: flood, osVersion: flood))
        try await waitForChange { service.isConnected }

        let bound = ObservedAgentInfo.maxFieldBytes
        let expected = String(repeating: "9", count: bound)
        #expect(service.agentVersion == expected)
        #expect(observed.values == [ObservedAgentInfo(agentVersion: expected, osVersion: expected)])
    }

    @Test("sendPolicyUpdate emits a PolicyUpdate frame with the supplied snapshot")
    func sendPolicyUpdateEmitsFrame() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = makeService(channel: host)
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)  // host hello
        // The clipboard bit is gated on the guest advertising streaming, so the
        // guest must Hello with the capability before a clipboard=true policy
        // survives the gate — and the service must have *observed* that Hello.
        try guest.send(makeGuestHello(agentVersion: "0.16.0"))
        try await waitForChange { service.guestSupportsClipboardStreaming }

        service.sendPolicyUpdate(
            AgentPolicySnapshot(
                logForwardingEnabled: false, clipboardSharingEnabled: true,
                clipboardMaxPasteBytes: ClipboardPasteLimit.defaultBytes)
        )

        var policy: Kernova_V1_PolicyUpdate?
        for _ in 0..<5 where policy == nil {
            let next = try await nextFrame(from: guest)
            if case .policyUpdate(let p) = next.payload {
                policy = p
            }
        }
        let received = try #require(policy)
        #expect(received.logForwardingEnabled == false)
        #expect(received.clipboardSharingEnabled == true)
    }

    // MARK: - Streaming capability gate

    @Test("clipboard stays disabled when the guest lacks the streaming capability")
    func clipboardGatedWithoutCapability() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = makeService(channel: host)
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)  // host hello
        // Guest that predates streaming: no clipboard.transfer.v3.
        try guest.send(makeGuestHello(agentVersion: "0.15.0", streamingCapable: false))

        service.sendPolicyUpdate(
            AgentPolicySnapshot(
                logForwardingEnabled: true, clipboardSharingEnabled: true,
                clipboardMaxPasteBytes: ClipboardPasteLimit.defaultBytes)
        )

        var policy: Kernova_V1_PolicyUpdate?
        for _ in 0..<6 where policy == nil {
            let next = try await nextFrame(from: guest)
            if case .policyUpdate(let p) = next.payload {
                policy = p
            }
        }
        let received = try #require(policy)
        // Log forwarding passes through; clipboard is forced off by the gate.
        #expect(received.logForwardingEnabled == true)
        #expect(received.clipboardSharingEnabled == false)
        #expect(service.guestSupportsClipboardStreaming == false)
    }

    @Test("clipboard is enabled when the guest advertises the streaming capability")
    func clipboardEnabledWithCapability() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = makeService(
            channel: host,
            policyProvider: {
                AgentPolicySnapshot(
                    logForwardingEnabled: false, clipboardSharingEnabled: true,
                    clipboardMaxPasteBytes: ClipboardPasteLimit.defaultBytes)
            })
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(agentVersion: "0.16.0", streamingCapable: true))

        var policy: Kernova_V1_PolicyUpdate?
        for _ in 0..<6 where policy == nil {
            let next = try await nextFrame(from: guest)
            if case .policyUpdate(let p) = next.payload {
                policy = p
            }
        }
        let received = try #require(policy)
        #expect(received.clipboardSharingEnabled == true)
        #expect(service.guestSupportsClipboardStreaming == true)
    }

    // MARK: - Paste ceiling

    private func pushCeiling(requested: Int) async throws -> UInt64 {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = makeService(
            channel: host,
            policyProvider: {
                AgentPolicySnapshot(
                    logForwardingEnabled: false, clipboardSharingEnabled: true,
                    clipboardMaxPasteBytes: requested)
            })
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(agentVersion: "0.54.0"))

        var policy: Kernova_V1_PolicyUpdate?
        for _ in 0..<6 where policy == nil {
            let next = try await nextFrame(from: guest)
            if case .policyUpdate(let p) = next.payload {
                policy = p
            }
        }
        return try #require(policy).clipboardMaxPasteBytes
    }

    @Test("the user's paste ceiling reaches the guest verbatim")
    func pasteCeilingReachesTheGuest() async throws {
        let raised = 16 * 1024 * 1024 * 1024
        #expect(try await pushCeiling(requested: raised) == UInt64(raised))
    }

    // MARK: - ObservedAgentInfo.boundedField

    @Test("An empty field normalizes to nil")
    func boundedFieldEmptyIsNil() {
        #expect(ObservedAgentInfo.boundedField("") == nil)
    }

    @Test("A field within the bound passes through verbatim")
    func boundedFieldWithinBoundIsVerbatim() {
        #expect(ObservedAgentInfo.boundedField("26.0.1") == "26.0.1")
        let atLimit = String(repeating: "a", count: ObservedAgentInfo.maxFieldBytes)
        #expect(ObservedAgentInfo.boundedField(atLimit) == atLimit)
    }

    @Test("An over-long field is clipped to the bound")
    func boundedFieldOverBoundIsClipped() {
        let bound = ObservedAgentInfo.maxFieldBytes
        let bounded = ObservedAgentInfo.boundedField(String(repeating: "a", count: bound + 1))
        #expect(bounded == String(repeating: "a", count: bound))
    }

    @Test("A single grapheme cluster of many scalars is still bounded")
    func boundedFieldBoundsOneLongCharacter() throws {
        // A `Character`-based prefix would let this through whole — it is one
        // Character however many combining marks it carries.
        let combining = "e" + String(repeating: "\u{0301}", count: 100_000)
        let bounded = try #require(ObservedAgentInfo.boundedField(combining))
        #expect(bounded.utf8.count <= ObservedAgentInfo.maxFieldBytes)
    }

    @Test("Newlines are stripped, so a version cannot forge a host log line")
    func boundedFieldStripsNewlines() {
        let forged = "1.0\nGuest agent connected for 'other-vm'"
        #expect(
            ObservedAgentInfo.boundedField(forged)
                == "1.0Guest agent connected for 'other-vm'")
    }

    @Test("Format characters are stripped, so a version cannot rewrite its label")
    func boundedFieldStripsFormatCharacters() {
        // U+202E is Cf, not Cc: a bidi override reverses the run that follows
        // it in every label the host renders the version into.
        #expect(ObservedAgentInfo.boundedField("26.\u{202E}0") == "26.0")
        #expect(ObservedAgentInfo.boundedField("2\u{200D}6.0") == "26.0")
        #expect(ObservedAgentInfo.boundedField("26.0\u{0000}") == "26.0")
    }

    @Test("A field of nothing but control characters normalizes to nil")
    func boundedFieldAllControlIsNil() {
        #expect(ObservedAgentInfo.boundedField(String(repeating: "\n", count: 128)) == nil)
    }

    @Test("The cut lands on a scalar boundary, never mid-scalar")
    func boundedFieldCutsWholeScalars() throws {
        // 3 bytes each: 21 fit in the bound and the 22nd does not, so the
        // result stops one byte short rather than splitting a scalar — which
        // would need a 3-byte U+FFFD to repair and overshoot the bound.
        let euros = String(repeating: "€", count: 100)
        let bounded = try #require(ObservedAgentInfo.boundedField(euros))
        #expect(bounded == String(repeating: "€", count: 21))
        #expect(!bounded.unicodeScalars.contains("\u{FFFD}"))
    }
}

/// MainActor-isolated recorder for the `onAgentInfoObserved` closure.
///
/// Reference type so the observer's closure capture and the test's read site
/// see the same buffer without `inout` shenanigans.
@MainActor
private final class ObservedRecorder {
    private(set) var values: [ObservedAgentInfo] = []

    /// Fires on every `append`; await it instead of polling `values.count`.
    let changed = AsyncGate()

    func append(_ value: ObservedAgentInfo) {
        values.append(value)
        changed.notify()
    }
}

/// Stand-in for `VMInstance.isLivePaused`, flipped by the test to freeze and
/// thaw the guest.
@MainActor
private final class SuspensionFlag {
    var isSuspended = false
}

/// Counts `onChannelLost` invocations, sampling service state at callback time.
///
/// `sampleAgentVersion` is assigned after the service exists, since the thing
/// worth sampling is the service the recorder is wired into.
@MainActor
private final class ChannelLostRecorder {
    private(set) var count = 0
    private(set) var sampledAgentVersions: [String?] = []

    var sampleAgentVersion: (@MainActor () -> String?)?

    /// Fires on every `record`; await it instead of polling `count`.
    let changed = AsyncGate()

    func record() {
        count += 1
        sampledAgentVersions.append(sampleAgentVersion.flatMap { $0() })
        changed.notify()
    }
}
