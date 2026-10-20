import Foundation
import KernovaKit
import KernovaTestSupport
import SwiftProtobuf
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VsockControlService", .caseScoped)
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

    /// Default outbound-heartbeat cadence: small, and harmless to every test
    /// (extra heartbeats only keep the connection alive).
    private static let testHeartbeat: TimeInterval = 0.04

    /// Production-scale windows for a test that crosses them on a
    /// `GatedEngineClock` instead of sleeping through them.
    ///
    /// The liveness tick derives to 20 s — `unresponsiveAfter / 3`, under the
    /// heartbeat interval — which is what tells it apart from the heartbeat
    /// sleep parked on the same clock.
    private static let gatedHeartbeat: TimeInterval = 25
    private static let gatedUnresponsive: TimeInterval = 60
    private static let gatedTerminate: TimeInterval = 120
    private static let gatedTick: TimeInterval = 20

    /// Advances `clock` by `interval` and runs the loop parked on that interval,
    /// `count` times, returning once the last run has finished.
    ///
    /// A run has finished once its loop parks again, or once it settled the
    /// service — which cancels the loop instead, and every sleep parked beside
    /// it, which is what wakes the wait.
    private func runLoop(
        every interval: TimeInterval, times count: Int, on clock: GatedEngineClock,
        of service: VsockControlService
    ) async throws {
        for _ in 0..<count {
            try await clock.parkedChanged.wait {
                clock.parked.contains { $0.seconds == interval }
                    || service.lifecycleTasksForTesting.allSatisfy(\.isCancelled)
            }
            guard let sleeper = clock.parked.first(where: { $0.seconds == interval }) else { return }
            let requested = clock.requestedSeconds.filter { $0 == interval }.count
            clock.advance(seconds: interval)
            clock.release(sleeper)
            try await clock.parkedChanged.wait {
                clock.requestedSeconds.filter { $0 == interval }.count > requested
                    || service.lifecycleTasksForTesting.allSatisfy(\.isCancelled)
            }
        }
    }

    /// Default liveness windows, far beyond any test's wall-clock budget, so the
    /// watchdog never acts on the real clock: a test that exercises it crosses
    /// the gated windows on a `GatedEngineClock` instead.
    private static let watchdogDisabledUnresponsive: TimeInterval = 3_600
    private static let watchdogDisabledTerminate: TimeInterval = 7_200

    /// Builds a service with the test cadences applied.
    ///
    /// Caller decides
    /// `bundledAgentVersion`. The service is NOT started — caller invokes
    /// `start()` after wiring the recorder.
    private func makeService(
        channel: VsockChannel,
        hostVersion: String = "1.0",
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
        let service = VsockControlService(
            channel: channel,
            label: "test",
            hostVersion: hostVersion,
            bundledAgentVersion: bundledAgentVersion,
            clock: clock,
            cadence: ControlChannelCadence(
                heartbeatInterval: heartbeatInterval ?? Self.testHeartbeat,
                unresponsiveAfter: unresponsiveAfter ?? Self.watchdogDisabledUnresponsive,
                terminateAfter: terminateAfter ?? Self.watchdogDisabledTerminate),
            policyProvider: policyProvider,
            onAgentInfoObserved: onAgentInfoObserved,
            isGuestSuspended: isGuestSuspended
        )
        service.onChannelLost = onChannelLost
        return service
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

    @Test("Host Hello advertises the host version and bundled agent version it was handed")
    func hostHelloAdvertisesHandedVersions() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = makeService(channel: host, hostVersion: "7.3", bundledAgentVersion: "0.9.0")
        service.start()
        defer { service.stop() }

        let received = try await nextFrame(from: guest)
        guard case .hello(let hello) = received.payload else {
            Issue.record("Expected hello payload, got \(String(describing: received.payload))")
            return
        }
        #expect(hello.agentInfo.agentVersion == "7.3")
        #expect(hello.bundledAgentVersion == "0.9.0")
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
        // watchdog stage can fire while the test asserts.
        //
        // 7 s is a value no default of this type produces, and it has to stay
        // that way: at the 5 s default, a loop that ignored the injected
        // interval and slept a literal 5 would park the sleep this test
        // releases and pass every round. `unresponsiveAfter` then puts the
        // derived liveness tick at 3 s, which is what tells the two parked
        // sleeps apart.
        let heartbeatSeconds: TimeInterval = 7
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

        let clock = GatedEngineClock()
        let handled = FrameHandledRecorder()
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            clock: clock,
            heartbeatInterval: Self.gatedHeartbeat,
            unresponsiveAfter: Self.gatedUnresponsive,
            terminateAfter: Self.gatedTerminate
        )
        service.onFrameHandledForTesting = { handled.record() }
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }

        // Each heartbeat is judged two ticks — 40 s — after it lands. Only the
        // heartbeats keep that inside the 60 s window: without them the second
        // round judges 80 s of silence, and the fourth crosses terminate.
        for round in 1...4 {
            try guest.send(Frame.controlHeartbeat(nonce: UInt64(round)))
            try await handled.changed.wait { handled.count == round + 1 }
            try await runLoop(every: Self.gatedTick, times: 2, on: clock, of: service)
            #expect(service.agentStatus == .current(version: "0.9.0"))
        }
    }

    @Test("Silence past unresponsiveAfter flips agentStatus to .unresponsive")
    func silenceMarksUnresponsive() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let clock = GatedEngineClock()
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            clock: clock,
            heartbeatInterval: Self.gatedHeartbeat,
            unresponsiveAfter: Self.gatedUnresponsive,
            terminateAfter: Self.gatedTerminate
        )
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }

        // Three ticks judge 60 s, still inside the window; the fourth judges 80 s.
        try await runLoop(every: Self.gatedTick, times: 3, on: clock, of: service)
        #expect(service.agentStatus == .current(version: "0.9.0"))
        try await runLoop(every: Self.gatedTick, times: 1, on: clock, of: service)
        #expect(service.agentStatus == .unresponsive(version: "0.9.0"))
    }

    @Test("Resumed heartbeats restore agentStatus to .current")
    func recoveryFromUnresponsive() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let clock = GatedEngineClock()
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            clock: clock,
            heartbeatInterval: Self.gatedHeartbeat,
            unresponsiveAfter: Self.gatedUnresponsive,
            terminateAfter: Self.gatedTerminate
        )
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }

        // Four ticks of silence: 80 s, past unresponsive and short of terminate.
        try await runLoop(every: Self.gatedTick, times: 4, on: clock, of: service)
        #expect(service.agentStatus == .unresponsive(version: "0.9.0"))

        try guest.send(Frame.controlHeartbeat(nonce: 1))
        try await waitForChange { service.agentStatus == .current(version: "0.9.0") }
    }

    @Test("Silence past terminateAfter settles the service and stops the watchdog")
    func terminateSettlesTheService() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let clock = GatedEngineClock()
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            clock: clock,
            heartbeatInterval: Self.gatedHeartbeat,
            unresponsiveAfter: Self.gatedUnresponsive,
            terminateAfter: Self.gatedTerminate
        )

        service.start()
        defer { service.stop() }

        let lifecycleTasks = service.lifecycleTasksForTesting

        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }

        // Send nothing further: the seventh tick judges 140 s, past terminate.
        // The service has to settle rather than re-fire every tick against a
        // peer that has gone quiet for good.
        try await runLoop(every: Self.gatedTick, times: 7, on: clock, of: service)
        // `#require`: the tasks awaited below end only once the service settles.
        try #require(!service.isConnected)

        // Every periodic task runs to completion — no watchdog tick and no
        // heartbeat send survives the teardown.
        for task in lifecycleTasks {
            await task.value
        }
        #expect(service.agentVersion == nil)
        #expect(service.agentStatus == .waiting)
        // The channel went with it: the teardown closes before clearing
        // `isConnected`, so this is ordered, not racy.
        #expect(throws: VsockChannelError.closed) { try host.send(Frame.controlHeartbeat(nonce: 1)) }
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
        let lifecycleTasks = service.lifecycleTasksForTesting

        // A reconnect is served by a fresh instance built at accept time, so
        // restarting this one would only spin tasks against a dead socket.
        service.start()
        #expect(!service.isConnected)
        #expect(service.lifecycleTasksForTesting == lifecycleTasks)
    }

    // MARK: - Wrong-port payloads

    /// The control channel is the admission anchor every feature channel gates
    /// on — so unlike the log and drop channels, which settle on one, a payload
    /// belonging elsewhere may not take this one down: a single stray frame
    /// would otherwise flap the agent-status UI and every dependent channel.
    @Test("A payload belonging to another channel leaves the control channel up")
    func wrongPortPayloadLeavesTheChannelUp() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let lost = ChannelLostRecorder()
        let service = makeService(
            channel: host, bundledAgentVersion: "0.9.0", onChannelLost: { lost.record() })
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }

        // A clipboard offer on the control port: the guest talking out of turn.
        try guest.send(Frame.clipboardOffer(generation: 1, reps: [], isConcealed: false))
        // The frames are ordered on one channel, so a second Hello landing is
        // what proves the service kept serving past the stray one — no
        // observation window needed for a "still up" assertion.
        try guest.send(makeGuestHello(agentVersion: "0.9.1"))

        try await waitForChange { service.agentVersion == "0.9.1" }
        #expect(service.isConnected)
        #expect(lost.count == 0)
    }

    // MARK: - Live-paused guest

    @Test("A suspended guest is never judged silent, however long the pause runs")
    func suspendedGuestSurvivesTerminateWindow() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // A live-paused VM is frozen: the guest cannot answer a heartbeat, so
        // terminating for silence would blame the agent for the user's pause.
        let clock = GatedEngineClock()
        let suspension = SuspensionFlag()
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            clock: clock,
            heartbeatInterval: Self.gatedHeartbeat,
            unresponsiveAfter: Self.gatedUnresponsive,
            terminateAfter: Self.gatedTerminate,
            isGuestSuspended: { suspension.isSuspended }
        )
        service.start()
        defer { service.stop() }

        suspension.isSuspended = true
        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }

        // Eight ticks — 160 s, past the 120 s terminate window — with the guest
        // sending nothing at all.
        try await runLoop(every: Self.gatedTick, times: 8, on: clock, of: service)
        #expect(service.isConnected)
        #expect(service.agentStatus == .current(version: "0.9.0"))
    }

    @Test("A pause arms no deadline for a guest that has never spoken")
    func suspensionBeforeAnyFrameNeverExpires() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let clock = GatedEngineClock()
        let suspension = SuspensionFlag()
        let lost = ChannelLostRecorder()
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            clock: clock,
            heartbeatInterval: Self.gatedHeartbeat,
            unresponsiveAfter: Self.gatedUnresponsive,
            terminateAfter: Self.gatedTerminate,
            isGuestSuspended: { suspension.isSuspended },
            onChannelLost: { lost.record() }
        )
        // Suspended from the first tick, and the guest answers nothing: the
        // hold must not stand in for the Hello that never arrived, or resuming
        // hands the watchdog a deadline it can expire.
        suspension.isSuspended = true
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)  // host hello

        // A terminate window crossed held, then another crossed judged — eight
        // ticks is 160 s of watchdog time either way. Only the liveness loop is
        // ever released, so the frozen guest is never written to and every
        // second the watchdog sees is one this test added.
        try await runLoop(every: Self.gatedTick, times: 8, on: clock, of: service)
        suspension.isSuspended = false
        try await runLoop(every: Self.gatedTick, times: 8, on: clock, of: service)

        // Both windows crossed with nothing ever recorded: the watchdog has no
        // deadline to expire, held or judged.
        #expect(lost.count == 0)
        #expect(!service.isConnected)
        #expect(service.agentStatus == .waiting)
    }

    @Test("Suspension defers the liveness deadline rather than disabling it")
    func resumedGuestGetsAFreshWindow() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let clock = GatedEngineClock()
        let suspension = SuspensionFlag()
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            clock: clock,
            heartbeatInterval: Self.gatedHeartbeat,
            unresponsiveAfter: Self.gatedUnresponsive,
            terminateAfter: Self.gatedTerminate,
            isGuestSuspended: { suspension.isSuspended }
        )
        service.start()
        defer { service.stop() }

        suspension.isSuspended = true
        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }

        // 160 s held, guest sending nothing.
        try await runLoop(every: Self.gatedTick, times: 8, on: clock, of: service)
        #expect(service.isConnected)

        // Resuming hands the guest a window it can still miss: nothing has been
        // heard from it, so the deadline runs again from the last held tick, and
        // the seventh tick after it judges 140 s.
        suspension.isSuspended = false
        try await runLoop(every: Self.gatedTick, times: 7, on: clock, of: service)
        #expect(!service.isConnected)
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

        let clock = GatedEngineClock()
        let suspension = SuspensionFlag()
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            clock: clock,
            heartbeatInterval: Self.gatedHeartbeat,
            unresponsiveAfter: Self.gatedUnresponsive,
            terminateAfter: Self.gatedTerminate,
            isGuestSuspended: { suspension.isSuspended }
        )
        service.start()
        defer { service.stop() }

        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }
        // Prove the sender is genuinely running before freezing it, so a
        // silent-for-another-reason service can't pass this test.
        try await runLoop(every: Self.gatedHeartbeat, times: 1, on: clock, of: service)
        try await recorder.waitForFrames { recorder.heartbeats.count == 1 }

        suspension.isSuspended = true
        try await runLoop(every: Self.gatedHeartbeat, times: 3, on: clock, of: service)

        // The socket is FIFO, so whatever those intervals wrote precedes this
        // marker.
        try host.sendErrorFrame(code: "test.marker", message: "", inReplyTo: nil)
        try await recorder.waitForFrames { recorder.errors.contains { $0.code == "test.marker" } }
        #expect(recorder.heartbeats.count == 1)
    }

    // MARK: - onChannelLost

    @Test("onChannelLost fires when the liveness watchdog terminates a silent channel")
    func channelLostOnLivenessTerminate() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let clock = GatedEngineClock()
        let lost = ChannelLostRecorder()
        let service = makeService(
            channel: host,
            bundledAgentVersion: "0.9.0",
            clock: clock,
            heartbeatInterval: Self.gatedHeartbeat,
            unresponsiveAfter: Self.gatedUnresponsive,
            terminateAfter: Self.gatedTerminate,
            onChannelLost: { lost.record() }
        )
        lost.sample = { [weak service] in service?.agentVersion }
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }

        // The seventh silent tick judges 140 s, past terminate.
        try await runLoop(every: Self.gatedTick, times: 7, on: clock, of: service)
        #expect(lost.count == 1)
        // The callback runs on fully-settled state, which is what lets
        // `VMInstance` re-arm its agent watchdog on a nil `agentVersion`
        // instead of no-oping against the stale one.
        #expect(lost.samples == [nil])
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
        lost.sample = { [weak service] in service?.agentVersion }
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(agentVersion: "0.9.0"))
        try await waitForChange { service.isConnected }

        // The guest agent quits mid-session: EOF unwinds the consume loop.
        guest.close()

        try await lost.changed.wait { lost.count == 1 }
        #expect(lost.samples == [nil])
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
                    dropFilesEnabled: true,
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
                dropFilesEnabled: true,
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
                dropFilesEnabled: true,
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
                    dropFilesEnabled: true,
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
                    dropFilesEnabled: true, clipboardMaxPasteBytes: requested)
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

    @Test("A field within the bound passes through verbatim")
    func boundedFieldWithinBoundIsVerbatim() {
        #expect(ObservedAgentInfo.boundedField("26.0.1") == "26.0.1")
        let atLimit = String(repeating: "a", count: ObservedAgentInfo.maxFieldBytes)
        #expect(ObservedAgentInfo.boundedField(atLimit) == atLimit)
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
/// see the same buffer without `inout` shenanigans. Main-bound because
/// `onAgentInfoObserved` is `@MainActor` in production, not by convenience.
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

/// Counts the frames the service under test has handled, through
/// `onFrameHandledForTesting`.
@MainActor
private final class FrameHandledRecorder {
    private(set) var count = 0

    /// Fires on every `record`; await it instead of polling `count`.
    let changed = AsyncGate()

    func record() {
        count += 1
        changed.notify()
    }
}

/// Stand-in for `VMInstance.isLivePaused`, flipped by the test to freeze and
/// thaw the guest.
///
/// Main-bound because `isGuestSuspended` is `@MainActor` in production — the
/// heartbeat reads it from there — not by convenience.
@MainActor
private final class SuspensionFlag {
    var isSuspended = false
}
