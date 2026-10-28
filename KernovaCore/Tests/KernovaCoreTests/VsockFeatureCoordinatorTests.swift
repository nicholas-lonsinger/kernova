import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The descriptor table production drives every vsock channel from, and the
/// accept and teardown paths written once against it.
@Suite("VsockFeatureCoordinator", .caseScoped)
@MainActor
struct VsockFeatureCoordinatorTests {
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
        var config = VMConfiguration(
            name: "Gate VM", guestOS: .macOS, bootMode: .macOS, cpuCount: VMGuestOS.macOS.hostCPUCount,
            memorySizeInGB: VMGuestOS.macOS.hostMemorySize)
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

    @Test("A Linux session binds no channel with every toggle on, and a macOS one binds them all")
    func onlyAMacOSGuestBindsChannels() throws {
        func everyToggleOn(_ guestOS: VMGuestOS, _ bootMode: VMBootMode) -> VMConfiguration {
            var config = VMConfiguration(
                name: "Gate VM", guestOS: guestOS, bootMode: bootMode, cpuCount: guestOS.hostCPUCount,
                memorySizeInGB: guestOS.hostMemorySize)
            config.clipboardSharingEnabled = true
            config.agentLogForwardingEnabled = true
            config.dropFilesEnabled = true
            return config
        }
        let linux = everyToggleOn(.linux, .efi)
        let macOS = everyToggleOn(.macOS, .macOS)
        let (instance, sessionID) = makeInstanceWithLiveSession(named: "Coordinator VM")
        let vsock = try #require(instance.sessionContext?.vsock)

        for descriptor in VsockFeatureDescriptor.all {
            #expect(!descriptor.isEnabled(linux), "\(descriptor.name): enabled for Linux")
        }
        #expect(vsock.listeners(for: linux, sessionID: sessionID).isEmpty)
        #expect(
            vsock.listeners(for: macOS, sessionID: sessionID).map(\.port)
                == VsockFeatureDescriptor.all.flatMap(\.ports))
    }

    // MARK: - Accept

    @Test("A hand-off naming a released session builds nothing and closes the channel")
    func staleSessionHandOffIsRefused() async throws {
        for descriptor in VsockFeatureDescriptor.all {
            let (instance, _) = makeInstanceWithLiveSession(named: "Coordinator VM")
            let vsock = try #require(instance.sessionContext?.vsock)
            let (host, guest) = try makeStartedChannelPair()
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
        let (instance, sessionID) = makeInstanceWithLiveSession(named: "Coordinator VM")
        let vsock = try #require(instance.sessionContext?.vsock)
        var guests: [VsockChannel] = []
        defer { guests.forEach { $0.close() } }
        for descriptor in VsockFeatureDescriptor.all {
            let (host, guest) = try makeStartedChannelPair()
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
