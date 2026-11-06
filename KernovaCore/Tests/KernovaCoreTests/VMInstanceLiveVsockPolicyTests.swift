import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// What the live log toggle moves on the VM's socket device, and what it leaves
/// behind on the instance. The session owns the listener hosts, so a port
/// coming down and its host being released are one queue hop; these pin the
/// port the toggle moves.
@Suite("VMInstance live vsock policy", .caseScoped)
@MainActor
struct VMInstanceLiveVsockPolicyTests {
    // MARK: - Helpers

    /// This instance's live session coordinator, which the live-policy pass and
    /// the accept path both run through.
    private func coordinator(of instance: VMInstance) throws -> VsockFeatureCoordinator {
        try #require(instance.sessionContext?.vsock)
    }

    /// The listener production builds for `descriptor`, off the live session's
    /// coordinator.
    private func framedHost(
        for descriptor: VsockFeatureDescriptor, on instance: VMInstance, sessionID: UUID
    ) throws -> VsockListener {
        try #require(instance.sessionContext?.vsock).makeListener(for: descriptor, sessionID: sessionID)
    }

    /// Runs `host`'s accept path against a live peer, the way a guest dial
    /// installs the service behind a framed port.
    private func connectGuest(
        to host: VsockListener, keptOpenBy retained: inout [VsockChannel]
    ) async throws {
        let (acceptedFd, guestFd) = try makeRawSocketPair()
        let guest = VsockChannel(fileDescriptor: guestFd)
        guest.start()
        retained.append(guest)
        #expect(host.acceptDuplicatedFd(acceptedFd, dupErrno: 0))
        await drainMainQueue()
    }

    // MARK: - Log port

    @Test("Enabling log forwarding live installs the log listener")
    func enablingLogInstallsItsListener() async throws {
        let (instance, sessionID) = makeInstanceWithLiveSession(named: "Live Policy VM")
        let installer = MockVsockListenerInstall()

        try await coordinator(of: instance)
            .applyLive(.log, enabled: true, on: installer, sessionID: sessionID)

        #expect(installer.attached == [[KernovaVsockPort.log]])
        #expect(installer.detached.isEmpty)
    }

    @Test("Disabling log forwarding live withdraws the listener and stops the service")
    func disablingLogWithdrawsItsListener() async throws {
        let (instance, sessionID) = makeInstanceWithLiveSession(named: "Live Policy VM")
        var guests: [VsockChannel] = []
        defer { guests.forEach { $0.close() } }
        try await connectGuest(
            to: try framedHost(for: .log, on: instance, sessionID: sessionID),
            keptOpenBy: &guests)
        #expect(instance.vsockLogService != nil)

        let installer = MockVsockListenerInstall()
        try await coordinator(of: instance)
            .applyLive(.log, enabled: false, on: installer, sessionID: sessionID)

        #expect(installer.detached == [[KernovaVsockPort.log]])
        #expect(installer.attached.isEmpty)
        #expect(instance.vsockLogService == nil)
    }

    // MARK: - The channel dying under a service

    /// The keep-versus-nil half of the settle contract, pinned per service: the
    /// notification is uniform, the owner's reaction is not.
    @Test("A log channel dying under its service clears the instance's reference")
    func logChannelDeathClearsTheReference() async throws {
        let (instance, sessionID) = makeInstanceWithLiveSession(named: "Live Policy VM")
        var guests: [VsockChannel] = []
        defer { guests.forEach { $0.close() } }
        try await connectGuest(
            to: try framedHost(for: .log, on: instance, sessionID: sessionID),
            keptOpenBy: &guests)
        #expect(instance.vsockLogService != nil)

        // The guest agent quits mid-session. Nothing reads a settled log
        // service, so holding a dead channel until the next accept is pure
        // retention.
        guests.forEach { $0.close() }

        try await waitForChange { instance.vsockLogService == nil }
    }

    // MARK: - Hand-offs crossing a toggle-off

    /// The accept runs on the VM's queue and only queues its hand-off, so a
    /// toggle-off can land on main in between — unbinding the port and stopping
    /// the service while this connection is still on its way to rebuild them.
    /// The hand-off has to refuse, or the feature the user switched off keeps
    /// running on the accepted channel for the rest of the session.
    @Test("A log hand-off queued before the toggle-off installs nothing")
    func logHandOffCrossingDisableIsRefused() async throws {
        let library = makeWiredLibrary()
        let (instance, sessionID) = library.registerInstanceWithLiveSession(named: "Live Policy VM")
        let host = try framedHost(for: .log, on: instance, sessionID: sessionID)
        let (acceptedFd, guestFd) = try makeRawSocketPair()
        let guest = VsockChannel(fileDescriptor: guestFd)
        guest.start()
        defer { guest.close() }

        // Admitted while forwarding is on, so the refusal under test is the
        // hand-off's own and not the admission gate's.
        #expect(host.acceptDuplicatedFd(acceptedFd, dupErrno: 0))
        // The user toggles the setting off before the queued hand-off gets its
        // turn on main.
        library.editConfiguration(of: instance) { $0.agentLogForwardingEnabled = false }

        await drainMainQueue()

        #expect(instance.vsockLogService == nil)
        await expectEOF(on: guest)
    }
}
