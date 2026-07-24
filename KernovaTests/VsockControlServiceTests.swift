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
    private func makeGuestHello(agentVersion: String, streamingCapable: Bool = true) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities =
                streamingCapable
                ? KernovaCapability.controlChannelDefaults
                : [KernovaCapability.controlV1, KernovaCapability.controlHeartbeatV1]
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

    /// Default outbound-heartbeat cadence: small so `heartbeatOutboundCadence`
    /// doesn't drag, and harmless to every other test (extra heartbeats only
    /// keep the connection alive).
    private static let testHeartbeat: Duration = .milliseconds(40)

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
    /// The watchdog measures `ContinuousClock.now - lastInboundFrame`, which
    /// keeps advancing while a contended CI MainActor stalls the test. With the
    /// old 160 ms / 400 ms defaults, any non-watchdog test that paused past the
    /// window (waiting on a frame, a `waitUntil`, or scheduler jitter) saw the
    /// channel closed out from under it — surfacing as an EOF / `.closed` flake.
    /// Sixteen tests inherited those defaults despite not testing liveness; this
    /// makes the watchdog an explicit opt-in instead of an implicit deadline
    /// coupled to every test's runtime. See docs/TESTING.md "Async waits in tests".
    private static let watchdogDisabledUnresponsive: Duration = .seconds(3_600)
    private static let watchdogDisabledTerminate: Duration = .seconds(7_200)

    /// Builds a service with the test cadences applied.
    ///
    /// Caller decides
    /// `bundledAgentVersion`. The service is NOT started — caller invokes
    /// `start()` after wiring the recorder.
    private func makeService(
        channel: VsockChannel,
        bundledAgentVersion: String? = "0.9.0",
        heartbeatInterval: Duration? = nil,
        unresponsiveAfter: Duration? = nil,
        terminateAfter: Duration? = nil,
        policyProvider: (@MainActor () -> AgentPolicySnapshot)? = nil,
        onAgentVersionObserved: (@MainActor (String) -> Void)? = nil
    ) -> VsockControlService {
        VsockControlService(
            channel: channel,
            label: "test",
            bundledAgentVersion: bundledAgentVersion,
            heartbeatInterval: heartbeatInterval ?? Self.testHeartbeat,
            unresponsiveAfter: unresponsiveAfter ?? Self.watchdogDisabledUnresponsive,
            terminateAfter: terminateAfter ?? Self.watchdogDisabledTerminate,
            policyProvider: policyProvider,
            onAgentVersionObserved: onAgentVersionObserved
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
        // The host advertises streaming-clipboard support so the guest can
        // symmetrically gate clipboard on it.
        #expect(hello.capabilities.contains(KernovaCapability.clipboardStreamV1))
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
        // just sent a heartbeat. The watchdog's terminate stage stays disabled
        // (the makeService default): it is not under test, and a multi-second
        // stall in the sender loop once let a finite 5 s `terminateAfter` close
        // the channel out from under the test — the send then threw `.closed`.
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            heartbeatInterval: .milliseconds(200),
            unresponsiveAfter: .milliseconds(400)
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
            heartbeatInterval: .milliseconds(60),
            unresponsiveAfter: .milliseconds(100)
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
            heartbeatInterval: .milliseconds(60),
            unresponsiveAfter: .milliseconds(100)
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

        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }

        // Wait for a few terminateAfter windows. By then `checkLiveness`
        // should have fired and called `channel.close()` on the host side.
        // After teardown, `host.send(...)` raises `VsockChannelError.closed`.
        // RATIONALE: sanctioned exception-catch poll (docs/TESTING.md "Async
        // waits in tests") — closure is only detectable by a send raising
        // `.closed`; the watchdog closes the socket with no signal to await.
        try await waitUntil {
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
                AgentPolicySnapshot(logForwardingEnabled: true, clipboardSharingEnabled: false)
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

    // MARK: - onAgentVersionObserved

    @Test("onAgentVersionObserved fires once when the guest reports a non-empty version")
    func onAgentVersionObservedFires() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let observed = ObservedRecorder()
        let service = makeService(
            channel: host,
            onAgentVersionObserved: { observed.append($0) }
        )
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(agentVersion: "0.9.2"))
        try await waitForChange { service.isConnected }

        // The Hello handler runs synchronously after the inbound frame is
        // dispatched on the main actor, so by the time isConnected flips the
        // observer has already been invoked.
        #expect(observed.values == ["0.9.2"])
    }

    @Test("onAgentVersionObserved is skipped when the guest reports an empty version")
    func onAgentVersionObservedSkippedForEmpty() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let observed = ObservedRecorder()
        let service = makeService(
            channel: host,
            onAgentVersionObserved: { observed.append($0) }
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

    @Test("onAgentVersionObserved fires once per Hello (dedup is the caller's job)")
    func onAgentVersionObservedFiresPerHello() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let observed = ObservedRecorder()
        let service = makeService(
            channel: host,
            onAgentVersionObserved: { observed.append($0) }
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
        #expect(observed.values == ["0.9.2", "0.9.2"])
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
            AgentPolicySnapshot(logForwardingEnabled: false, clipboardSharingEnabled: true)
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
        // Guest that predates streaming: no clipboard.stream.v1.
        try guest.send(makeGuestHello(agentVersion: "0.15.0", streamingCapable: false))

        service.sendPolicyUpdate(
            AgentPolicySnapshot(logForwardingEnabled: true, clipboardSharingEnabled: true)
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
                AgentPolicySnapshot(logForwardingEnabled: false, clipboardSharingEnabled: true)
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
}

/// MainActor-isolated recorder for the `onAgentVersionObserved` closure.
///
/// Reference type so the observer's closure capture and the test's read site
/// see the same buffer without `inout` shenanigans.
@MainActor
private final class ObservedRecorder {
    private(set) var values: [String] = []

    /// Fires on every `append`; await it instead of polling `values.count`.
    let changed = AsyncGate()

    func append(_ value: String) {
        values.append(value)
        changed.notify()
    }
}
