import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import SwiftProtobuf
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// A mid-session agent disappearance, end to end over a real control channel:
/// `VMInstance.makeControlService(for:)` wires the hooks the accept path
/// installs, and an agent that said Hello this session never warns once it
/// leaves (`MissingAgentRule`).
@Suite("VMInstance agent reconnect", .caseScoped)
@MainActor
struct VMInstanceAgentReconnectTests {
    // MARK: - Helpers

    /// The version both the persisted `lastSeenAgentVersion` and the guest's
    /// `Hello` report, so a connected agent renders `.current` rather than
    /// `.outdated` against whatever the host bundles.
    private func bundledAgentVersion() throws -> String {
        try #require(BundledGuestAgents.testing.macOSVersion)
    }

    private func makeInstance(
        agentVersion: String, phase: VMLifecyclePhase = .running(sessionID: UUID())
    ) -> VMInstance {
        let instance = VMInstanceFixture.make(
            name: "Reconnect VM", guestOS: .macOS, phase: phase,
            mutate: { $0.lastSeenAgentVersion = agentVersion })
        // The phase supplies the session identity the control channel's accept
        // binds to; the context is what the service and `agentStatus` live in.
        instance.beginSessionContextForTesting()
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
    /// pair, and returns the guest end for the test to drive.
    ///
    /// Runs the production accept ritual rather than restating it, so the
    /// channel-loss re-arm these tests turn on is the one the coordinator
    /// wires.
    private func attachControlService(to instance: VMInstance) throws -> VsockChannel {
        let (guestFd, hostFd) = try makeRawSocketPair()
        let guest = VsockChannel(fileDescriptor: guestFd)
        let host = VsockChannel(fileDescriptor: hostFd)
        guest.start()
        host.start()

        let vsock = try #require(instance.sessionContext?.vsock)
        vsock.accept(
            host, as: VsockFeatureDescriptor.control,
            sessionID: try #require(instance.liveSessionID))
        return guest
    }

    // MARK: - Tests

    @Test("Row 3: an agent that disappears after its Hello this session reads connecting and never warns")
    func channelLossRearmsTheWatchdog() async throws {
        let version = try bundledAgentVersion()
        let instance = makeInstance(agentVersion: version)
        let guest = try attachControlService(to: instance)
        defer {
            instance.cancelAgentAbsenceWatchdog()
            instance.stopVsockServices()
            guest.close()
        }

        try guest.send(makeGuestHello(agentVersion: version))
        try await waitForChange { instance.vsockControlService?.agentVersion != nil }
        #expect(instance.agentPresentation?.status == .current(version: version))
        #expect(instance.hasSeenAgentThisSession)
        // A connected agent is nothing to wait for.
        #expect(instance.agentAbsenceTimerForTesting == nil)

        // The guest agent quits — its user logged out, or it crashed. It
        // connected this session, so its absence is not a missing install.
        guest.close()
        try await waitForChange { instance.vsockControlService?.isConnected == false }

        // `onChannelLost` runs inside the settle, so the rule has read it by
        // the time the settle is observable.
        #expect(instance.agentAbsenceTimerForTesting == nil)
        #expect(instance.agentPresentation?.status == .connecting(expected: version))
    }

    @Test("Row 3: a replacement channel that never handshakes, after a Hello this session, never warns")
    func wedgedReplacementChannelStillEscalates() async throws {
        // Replacing a live service settles the old one as owner-requested, so
        // `onChannelLost` stays silent and the accept path reads the rule. The
        // agent connected this session, so the rule finds nothing missing.
        let version = try bundledAgentVersion()
        let instance = makeInstance(agentVersion: version)
        let first = try attachControlService(to: instance)
        defer {
            instance.cancelAgentAbsenceWatchdog()
            instance.stopVsockServices()
            first.close()
        }

        try first.send(makeGuestHello(agentVersion: version))
        try await waitForChange { instance.vsockControlService?.agentVersion != nil }
        #expect(instance.agentAbsenceTimerForTesting == nil)

        // A second connection arrives while the first is still healthy, then
        // wedges: open, but never a valid Hello.
        let second = try attachControlService(to: instance)
        defer { second.close() }
        #expect(instance.agentPresentation?.status == .connecting(expected: version))
        #expect(instance.agentAbsenceTimerForTesting == nil)
        instance.agentAbsenceGrace = .milliseconds(200)
        instance.startAgentAbsenceWatch()
        #expect(instance.agentAbsenceTimerForTesting == nil)
    }

    @Test("An owner teardown of the control service arms nothing")
    func ownerTeardownArmsNothing() async throws {
        let version = try bundledAgentVersion()
        let instance = makeInstance(agentVersion: version)
        let guest = try attachControlService(to: instance)
        defer {
            instance.cancelAgentAbsenceWatchdog()
            guest.close()
        }

        try guest.send(makeGuestHello(agentVersion: version))
        try await waitForChange { instance.vsockControlService?.agentVersion != nil }

        // `stopVsockServices()` is the session teardown path; arming a grace
        // clock against a VM being shut down would be pure noise.
        instance.stopVsockServices()
        #expect(instance.agentAbsenceTimerForTesting == nil)
    }

    @Test("Pausing a VM disturbs neither the control channel nor the agent badge")
    func pausingLeavesTheAgentBadgeAlone() async throws {
        // Pausing tears nothing down and arms no grace clock, so the badge a
        // user sees does not flinch when they pause. The liveness deadline held
        // while frozen is the control service's own, pinned by
        // `VsockControlServiceTests.suspendedGuestSurvivesTerminateWindow`.
        let version = try bundledAgentVersion()
        let instance = makeInstance(agentVersion: version)
        let guest = try attachControlService(to: instance)
        defer {
            instance.cancelAgentAbsenceWatchdog()
            instance.stopVsockServices()
            guest.close()
        }

        try guest.send(makeGuestHello(agentVersion: version))
        try await waitForChange { instance.vsockControlService?.agentVersion != nil }

        instance.activity.placeForTesting(.livePaused(sessionID: try #require(instance.liveSessionID)))
        #expect(instance.isLivePaused)
        #expect(instance.vsockControlService?.isConnected == true)
        #expect(instance.agentAbsenceTimerForTesting == nil)
        #expect(instance.agentExpectedButMissing == false)
        #expect(instance.agentPresentation?.status == .current(version: version))
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
            instance.cancelAgentAbsenceWatchdog()
            instance.stopVsockServices()
            guest.close()
        }

        try guest.send(makeGuestHello(agentVersion: version))
        try await waitForChange { instance.vsockControlService?.agentVersion != nil }

        instance.activity.placeForTesting(.suspended)
        guest.close()
        try await waitForChange { instance.vsockControlService?.isConnected == false }

        #expect(instance.agentAbsenceTimerForTesting == nil)

        // Resuming within the session arms nothing either: the agent
        // connected this session.
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        instance.agentAbsenceGrace = .milliseconds(200)
        instance.startAgentAbsenceWatch()
        #expect(instance.agentAbsenceTimerForTesting == nil)
        #expect(instance.agentPresentation?.status == .connecting(expected: version))
    }
}
