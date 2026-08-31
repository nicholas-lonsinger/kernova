import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The #706 mid-session escalation, end to end over a real control channel:
/// `VMInstance.makeControlService(for:)` wires the hooks the accept path
/// installs, so an agent that disappears mid-session escalates past
/// `.connecting` instead of spinning there for the rest of the session.
@Suite("VMInstance agent reconnect escalation", .admissionGated)
@MainActor
struct VMInstanceAgentReconnectTests {
    // MARK: - Helpers

    /// The version both the persisted `lastSeenAgentVersion` and the guest's
    /// `Hello` report, so a connected agent renders `.current` rather than
    /// `.outdated` against whatever the host bundles.
    private func bundledAgentVersion() throws -> String {
        try #require(KernovaMacOSAgentInfo.bundledVersion)
    }

    private func makeInstance(
        agentVersion: String, phase: VMLifecyclePhase = .running(sessionID: UUID())
    ) -> VMInstance {
        var config = VMConfiguration(name: "Reconnect VM", guestOS: .macOS, bootMode: .macOS)
        config.lastSeenAgentVersion = agentVersion
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL, phase: phase)
        // `agentStatus` synthesis keys off a live `VZVirtualMachine`, which no
        // CI host can create — the phase's session identity stands in for one,
        // not for the session context the control service lives in.
        instance.beginSessionContext()
        return instance
    }

    private func makeGuestHello(agentVersion: String) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities = KernovaCapability.controlChannelDefaults
            $0.agentInfo = Kernova_V1_AgentInfo.with {
                $0.os = "macOS"
                $0.osVersion = "26.0"
                $0.agentVersion = agentVersion
            }
        }
        return frame
    }

    /// Installs a production-wired control service on `instance` over a socket
    /// pair, mirroring what the accept closure in `startVsockServices()` does,
    /// and returns the guest end for the test to drive.
    ///
    /// Every step the accept closure takes, in its order — settle whatever is
    /// installed, build, install, start, arm.
    private func attachControlService(to instance: VMInstance) throws -> VsockChannel {
        let (guestFd, hostFd) = try makeRawSocketPair()
        let guest = VsockChannel(fileDescriptor: guestFd)
        let host = VsockChannel(fileDescriptor: hostFd)
        guest.start()
        host.start()

        instance.sessionContext?.vsockControlService?.stop()
        let service = instance.makeControlService(for: host)
        instance.sessionContext?.vsockControlService = service
        service.start()
        instance.startAgentPostStartWatchdog()
        return guest
    }

    // MARK: - Tests

    @Test("An agent that disappears mid-session re-arms the watchdog")
    func channelLossRearmsTheWatchdog() async throws {
        let version = try bundledAgentVersion()
        let instance = makeInstance(agentVersion: version)
        let guest = try attachControlService(to: instance)
        defer {
            instance.cancelAgentPostStartWatchdog()
            instance.stopVsockServices()
            guest.close()
        }

        try guest.send(makeGuestHello(agentVersion: version))
        try await waitForChange { instance.vsockControlService?.agentVersion != nil }
        #expect(instance.agentStatus == .current(version: version))
        #expect(instance.hasSeenAgentThisSession)
        // A connected agent is nothing to wait for.
        #expect(instance.agentPostStartTaskForTesting == nil)

        // The guest agent quits. Before #706 the status parked at `.connecting`
        // with nothing left to escalate it.
        guest.close()
        try await waitForChange { instance.vsockControlService?.isConnected == false }

        // `onChannelLost` runs inside the settle, so the re-arm is already done
        // by the time the settle is observable.
        #expect(instance.agentPostStartTaskForTesting != nil)
        #expect(instance.agentStatus == .connecting(expected: version))
    }

    @Test("A replacement channel that never handshakes still escalates")
    func wedgedReplacementChannelStillEscalates() async throws {
        // Replacing a live service settles the old one as owner-requested, so
        // `onChannelLost` stays silent — the accept path's own arm is the only
        // thing standing between a connect-but-never-Hello agent (a
        // half-finished update) and a spinner that never resolves.
        let version = try bundledAgentVersion()
        let instance = makeInstance(agentVersion: version)
        let first = try attachControlService(to: instance)
        defer {
            instance.cancelAgentPostStartWatchdog()
            instance.stopVsockServices()
            first.close()
        }

        try first.send(makeGuestHello(agentVersion: version))
        try await waitForChange { instance.vsockControlService?.agentVersion != nil }
        #expect(instance.agentPostStartTaskForTesting == nil)

        // A second connection arrives while the first is still healthy, then
        // wedges: open, but never a valid Hello.
        let second = try attachControlService(to: instance)
        defer { second.close() }
        #expect(instance.agentStatus == .connecting(expected: version))
        #expect(instance.agentPostStartTaskForTesting != nil)

        // Re-arm short to watch that clock actually run out.
        instance.cancelAgentPostStartWatchdog()
        instance.startAgentPostStartWatchdog(grace: .milliseconds(200))
        await instance.agentPostStartTaskForTesting?.value
        #expect(instance.agentStatus == .expectedMissing(expected: version))
    }

    @Test("An owner teardown of the control service arms nothing")
    func ownerTeardownArmsNothing() async throws {
        let version = try bundledAgentVersion()
        let instance = makeInstance(agentVersion: version)
        let guest = try attachControlService(to: instance)
        defer {
            instance.cancelAgentPostStartWatchdog()
            guest.close()
        }

        try guest.send(makeGuestHello(agentVersion: version))
        try await waitForChange { instance.vsockControlService?.agentVersion != nil }

        // `stopVsockServices()` is the session teardown path; arming a grace
        // clock against a VM being shut down would be pure noise.
        instance.stopVsockServices()
        #expect(instance.agentPostStartTaskForTesting == nil)
    }

    @Test("Pausing a VM disturbs neither the control channel nor the agent badge")
    func pausingLeavesTheAgentBadgeAlone() async throws {
        // Scoped to what a production-cadence service can show in a short
        // window: pausing tears nothing down synchronously and arms no grace
        // clock, so the badge a user sees does not flinch when they pause.
        //
        // It does NOT cover the deadline being held while frozen — the first
        // liveness tick is 5 s away at production cadences. That property needs
        // injected windows and lives in
        // `VsockControlServiceTests.suspendedGuestSurvivesTerminateWindow`.
        let version = try bundledAgentVersion()
        let instance = makeInstance(agentVersion: version)
        let guest = try attachControlService(to: instance)
        defer {
            instance.cancelAgentPostStartWatchdog()
            instance.stopVsockServices()
            guest.close()
        }

        try guest.send(makeGuestHello(agentVersion: version))
        try await waitForChange { instance.vsockControlService?.agentVersion != nil }

        instance.enter(.livePaused(sessionID: try #require(instance.liveSessionID)))
        #expect(instance.isLivePaused)

        // RATIONALE: negative assertion ("prove nothing was torn down or
        // armed") — a fixed observation window, per docs/TESTING.md "Async
        // waits in tests".
        try await Task.sleep(for: .milliseconds(500))
        #expect(instance.vsockControlService?.isConnected == true)
        #expect(instance.agentPostStartTaskForTesting == nil)
        #expect(instance.agentExpectedButMissing == false)
        #expect(instance.agentStatus == .current(version: version))
    }

    @Test("A channel lost while live-paused still arms nothing")
    func livePausedChannelLossArmsNothing() async throws {
        // Belt and braces for the same trap: even if the channel does go away
        // during a pause — the guest agent crashed before the freeze, say — the
        // `.running` guard keeps the grace clock off until the VM is executing.
        let version = try bundledAgentVersion()
        let instance = makeInstance(agentVersion: version)
        let guest = try attachControlService(to: instance)
        defer {
            instance.cancelAgentPostStartWatchdog()
            instance.stopVsockServices()
            guest.close()
        }

        try guest.send(makeGuestHello(agentVersion: version))
        try await waitForChange { instance.vsockControlService?.agentVersion != nil }

        instance.enter(.suspended)
        guest.close()
        try await waitForChange { instance.vsockControlService?.isConnected == false }

        #expect(instance.agentPostStartTaskForTesting == nil)

        // Resuming is what starts the clock — and the resumed VM is exactly the
        // case that must escalate.
        instance.enter(.running(sessionID: UUID()))
        instance.startAgentPostStartWatchdog(grace: .milliseconds(200))
        await instance.agentPostStartTaskForTesting?.value
        #expect(instance.agentStatus == .expectedMissing(expected: version))
    }
}
