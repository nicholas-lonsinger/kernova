import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The #706 mid-session escalation, end to end over a real control channel:
/// `VMInstance.makeControlService(for:)` wires the hooks the accept path
/// installs, so an agent that disappears mid-session escalates past
/// `.connecting` instead of spinning there for the rest of the session.
@Suite("VMInstance agent reconnect escalation")
@MainActor
struct VMInstanceAgentReconnectTests {
    // MARK: - Helpers

    /// The version both the persisted `lastSeenAgentVersion` and the guest's
    /// `Hello` report, so a connected agent renders `.current` rather than
    /// `.outdated` against whatever the host bundles.
    private func bundledAgentVersion() throws -> String {
        try #require(KernovaMacOSAgentInfo.bundledVersion)
    }

    private func makeInstance(agentVersion: String, status: VMStatus = .running) -> VMInstance {
        var config = VMConfiguration(name: "Reconnect VM", guestOS: .macOS, bootMode: .macOS)
        config.lastSeenAgentVersion = agentVersion
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL, status: status)
        // `agentStatus` synthesis keys off a live VZVirtualMachine, which no CI
        // host can create.
        instance.hasLiveVirtualMachineOverrideForTesting = true
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
    private func attachControlService(to instance: VMInstance) throws -> VsockChannel {
        let (guestFd, hostFd) = try makeRawSocketPair()
        let guest = VsockChannel(fileDescriptor: guestFd)
        let host = VsockChannel(fileDescriptor: hostFd)
        guest.start()
        host.start()

        let service = instance.makeControlService(for: host)
        instance.vsockControlService = service
        service.start()
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

    @Test("A live-paused VM keeps its channel and never escalates")
    func livePausedVMKeepsItsChannel() async throws {
        // The trap #706 called out: the liveness watchdog terminates a silent
        // channel, a paused guest is silent by definition, and the re-arm would
        // then put a "didn't reconnect" warning on a VM the user merely paused.
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

        instance.status = .paused
        #expect(instance.isLivePaused)

        // RATIONALE: negative assertion ("prove neither the channel teardown
        // nor the watchdog fired") — a fixed observation window, per
        // docs/TESTING.md "Async waits in tests". The service runs production
        // liveness windows, so this only has to outlast a mistaken immediate
        // teardown, not the 30 s terminate deadline.
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

        instance.status = .paused
        guest.close()
        try await waitForChange { instance.vsockControlService?.isConnected == false }

        #expect(instance.agentPostStartTaskForTesting == nil)

        // Resuming is what starts the clock — and the resumed VM is exactly the
        // case that must escalate.
        instance.status = .running
        instance.startAgentPostStartWatchdog(grace: .milliseconds(200))
        await instance.agentPostStartTaskForTesting?.value
        #expect(instance.agentStatus == .expectedMissing(expected: version))
    }
}
