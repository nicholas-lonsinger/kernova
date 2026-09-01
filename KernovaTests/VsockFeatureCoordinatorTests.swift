import Darwin
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The descriptor table production drives every vsock channel from, and the
/// accept and teardown paths written once against it.
@Suite("VsockFeatureCoordinator", .admissionGated)
@MainActor
struct VsockFeatureCoordinatorTests {
    // MARK: - Helpers

    private final class RetainingAcceptor: VsockDataConnectionAccepting {
        nonisolated func acceptDataConnection(fd: Int32) {
            // Keep the descriptor open: a forwarded fd is the probe's signal.
        }
    }

    /// An instance with a live session and a completed handshake, every feature
    /// toggled on so each descriptor's accept path is reachable.
    private func makeInstanceWithLiveSession() -> (instance: VMInstance, sessionID: UUID) {
        var config = VMConfiguration(name: "Coordinator VM", guestOS: .macOS, bootMode: .macOS)
        config.clipboardSharingEnabled = true
        config.agentLogForwardingEnabled = true
        config.dropFilesEnabled = true
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL)
        let sessionID = UUID()
        instance.enter(.running(sessionID: sessionID))
        instance.beginSessionContext()
        instance.vsockAdmissionGate.publish(
            VsockAdmissionGate.State(
                handshakeComplete: true,
                capabilities: Set(KernovaCapability.controlChannelDefaults)))
        return (instance, sessionID)
    }

    /// Asserts `sink` forwards nothing — a descriptor handed to it is closed,
    /// which the peer of a socket pair sees as EOF.
    private func expectSinkCleared(_ sink: VsockDataConnectionSink) throws {
        let (a, b) = try makeRawSocketPair()
        defer { close(b) }  // `a` is owned — and must be closed — by the sink.
        sink.accept(fd: a)
        #expect(fcntl(b, F_SETFL, O_NONBLOCK) >= 0)
        var byte: UInt8 = 0
        #expect(recv(b, &byte, 1, 0) == 0)
    }

    // MARK: - The table

    /// A collision would silently hand one channel's connections to another's
    /// listener, and a port outside the registry would bind nothing a guest
    /// dials.
    @Test("Every descriptor binds distinct ports drawn from the registry")
    func descriptorPortsAreDistinctAndRegistered() {
        let registered: Set<UInt32> = [
            KernovaVsockPort.control, KernovaVsockPort.clipboard, KernovaVsockPort.log,
            KernovaVsockPort.drop, KernovaVsockPort.clipboardData, KernovaVsockPort.dropData,
        ]
        let ports = VsockFeatureDescriptor.all.flatMap(\.ports)

        #expect(Set(ports).count == ports.count)
        #expect(Set(ports).isSubset(of: registered))
        // The framed port comes first, so a pair installs the channel ahead of
        // the data port that only has meaning behind it.
        #expect(VsockFeatureDescriptor.clipboard.ports.first == KernovaVsockPort.clipboard)
        #expect(VsockFeatureDescriptor.drop.ports.first == KernovaVsockPort.drop)
    }

    /// Gating the control channel on the gate its own handshake fills would
    /// deadlock every session.
    @Test("Only the control channel skips the admission gate, and each feature names its capability")
    func onlyControlSkipsAdmission() {
        #expect(VsockFeatureDescriptor.control.requirement == nil)
        for descriptor in [VsockFeatureDescriptor.log, .clipboard, .drop] {
            #expect(descriptor.requirement != nil, "\(descriptor.name): admits ungated")
        }
        // Log forwarding asks for the handshake and nothing more.
        #expect(VsockFeatureDescriptor.log.requirement?.capability == nil)
        #expect(
            VsockFeatureDescriptor.clipboard.requirement?.capability
                == KernovaCapability.clipboardTransferV3)
        #expect(
            VsockFeatureDescriptor.drop.requirement?.capability == KernovaCapability.dropFilesV3)
    }

    @Test("Each descriptor's install-time gate tracks its own configuration flag")
    func isEnabledTracksItsFlag() {
        var config = VMConfiguration(name: "Gate VM", guestOS: .macOS, bootMode: .macOS)
        config.clipboardSharingEnabled = false
        config.agentLogForwardingEnabled = false
        config.dropFilesEnabled = false

        // The control plane runs whatever the feature toggles say.
        #expect(VsockFeatureDescriptor.control.isEnabled(config))
        #expect(!VsockFeatureDescriptor.log.isEnabled(config))
        #expect(!VsockFeatureDescriptor.clipboard.isEnabled(config))
        #expect(!VsockFeatureDescriptor.drop.isEnabled(config))

        config.clipboardSharingEnabled = true
        config.agentLogForwardingEnabled = true
        config.dropFilesEnabled = true

        #expect(VsockFeatureDescriptor.log.isEnabled(config))
        #expect(VsockFeatureDescriptor.clipboard.isEnabled(config))
        #expect(VsockFeatureDescriptor.drop.isEnabled(config))
    }

    /// The predicate that has to stay separate from the install-time one: a
    /// Linux guest's sharing rides the SPICE console port, so live-toggling
    /// vsock listeners there would install ports nothing dials.
    @Test("Clipboard applies live only to macOS guests, unlike log and drop")
    func clipboardAppliesLiveOnlyToMacOS() {
        let linux = VMConfiguration(name: "Linux VM", guestOS: .linux, bootMode: .efi)
        let macOS = VMConfiguration(name: "macOS VM", guestOS: .macOS, bootMode: .macOS)

        #expect(!VsockFeatureDescriptor.clipboard.appliesLive(linux))
        #expect(VsockFeatureDescriptor.clipboard.appliesLive(macOS))
        for descriptor in [VsockFeatureDescriptor.log, .drop] {
            #expect(descriptor.appliesLive(linux))
            #expect(descriptor.appliesLive(macOS))
        }
    }

    // MARK: - Accept

    @Test("A hand-off naming a released session builds nothing and closes the channel")
    func staleSessionHandOffIsRefused() async throws {
        for descriptor in VsockFeatureDescriptor.all {
            let (instance, _) = makeInstanceWithLiveSession()
            let vsock = try #require(instance.sessionContext?.vsock)
            let (hostFd, guestFd) = try makeRawSocketPair()
            let guest = VsockChannel(fileDescriptor: guestFd)
            let host = VsockChannel(fileDescriptor: hostFd)
            guest.start()
            host.start()
            defer { guest.close() }

            vsock.accept(host, as: descriptor, sessionID: UUID())

            #expect(
                vsock.service(for: descriptor) == nil,
                "\(descriptor.name): a stale hand-off installed a service")
            await expectEOF(on: guest)
        }
    }

    // MARK: - Teardown

    @Test("stopAll settles every slot and clears the gate and both data sinks")
    func stopAllReleasesEverything() async throws {
        let (instance, sessionID) = makeInstanceWithLiveSession()
        let vsock = try #require(instance.sessionContext?.vsock)
        var guests: [VsockChannel] = []
        defer { guests.forEach { $0.close() } }
        for descriptor in VsockFeatureDescriptor.all {
            let (hostFd, guestFd) = try makeRawSocketPair()
            let guest = VsockChannel(fileDescriptor: guestFd)
            let host = VsockChannel(fileDescriptor: hostFd)
            guest.start()
            host.start()
            guests.append(guest)
            vsock.accept(host, as: descriptor, sessionID: sessionID)
            #expect(
                vsock.service(for: descriptor) != nil,
                "\(descriptor.name): the accept installed nothing to settle")
        }
        instance.vsockAdmissionGate.publish(
            VsockAdmissionGate.State(handshakeComplete: true))

        vsock.stopAll()

        for descriptor in VsockFeatureDescriptor.all {
            #expect(
                vsock.service(for: descriptor) == nil,
                "\(descriptor.name): the slot survived the teardown")
        }
        #expect(instance.vsockAdmissionGate.admission(for: .none) != .admit)
        try expectSinkCleared(instance.clipboardDataSink)
        try expectSinkCleared(instance.dropDataSink)
        instance.cancelAgentPostStartWatchdog()
    }
}
