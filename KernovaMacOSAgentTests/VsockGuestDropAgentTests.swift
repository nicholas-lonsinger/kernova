import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

/// Unit tests for when the guest's drag-out channel dials the host.
@Suite("VsockGuestDropAgent", .caseScoped)
struct VsockGuestDropAgentTests {
    // MARK: - Harness

    /// The agent under test and the host end of its channel.
    private final class Harness {
        let agent: VsockGuestDropAgent
        let host: VsockChannel
        /// The peer ends of every data connection the agent has dialled.
        let dialled = DialledDataConnections()
        let reporter: ClipboardTransferReporter
        let stagingRoot = TestStagingRoot()
        /// The reconnect loop's clock, which counts the sleeps between attempts.
        let clientClock = SleepCountingEngineClock(wrapping: MonotonicEngineClock())
        /// How many times the reconnect loop has asked for a socket.
        let provided = AtomicInt()

        init() throws {
            let (agentFd, hostFd) = try makeRawSocketPair()
            host = VsockChannel(fileDescriptor: hostFd)
            host.start()

            let provided = self.provided
            let client = VsockGuestClient(
                port: KernovaVsockPort.drop, label: "drop-test",
                clock: clientClock, retryInterval: 0.05
            ) { _, _ in
                provided.increment() == 1 ? .success(agentFd) : .failure(.transient("test: no fd"))
            }
            reporter = ClipboardTransferReporter(clock: TestEngineClock())
            agent = VsockGuestDropAgent(
                client: client, reporter: reporter, stagingRoot: stagingRoot.root, dataDialer: dialled.dialer)
            agent.applyHostCapabilities(.init(supportsDropFiles: true, dragOut: .none))
        }

        func tearDown() {
            agent.stop()
            host.close()
            dialled.closeAll()
        }
    }

    // MARK: - Enablement

    @Test("the client stays paused until the host advertises the capability")
    func staysPausedWithoutTheCapability() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.agent.applyHostCapabilities(.unadvertised)

        harness.agent.start()
        harness.agent.applyPolicy(enabled: true)
        // A host with no drop listener is never redialled. Each sleep follows
        // an iteration's connect-or-skip decision, so the second proves two
        // iterations passed it up.
        try await harness.clientClock.sleepRequested.wait { harness.clientClock.sleepCount >= 2 }
        #expect(harness.provided.value == 0)
        #expect(harness.agent.liveChannelForTesting == nil)

        // The capability arriving is what starts the client.
        harness.agent.applyHostCapabilities(.init(supportsDropFiles: true, dragOut: .none))
        try await waitUntil { harness.agent.liveChannelForTesting != nil }
    }

    @Test("the client stays paused while the host's policy has drag and drop off")
    func staysPausedWhilePolicyIsOff() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        // The host binds no drop port while its per-VM toggle is off, so a
        // capable host that has switched the feature off must not be dialled
        // either.
        harness.agent.applyPolicy(enabled: false)

        harness.agent.start()
        try await harness.clientClock.sleepRequested.wait { harness.clientClock.sleepCount >= 2 }
        #expect(harness.provided.value == 0)
        #expect(harness.agent.liveChannelForTesting == nil)

        harness.agent.applyPolicy(enabled: true)
        // No-signal poll — the lifecycle read is SUT-internal state with
        // nothing to await on.
        try await waitUntil { harness.agent.liveChannelForTesting != nil }
    }
}
