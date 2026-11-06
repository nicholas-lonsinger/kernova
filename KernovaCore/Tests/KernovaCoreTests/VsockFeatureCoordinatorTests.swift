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
    @Test("Every descriptor binds a distinct port drawn from the registry")
    func descriptorPortsAreDistinctAndRegistered() {
        let registered: Set<UInt32> = [
            KernovaVsockPort.control, KernovaVsockPort.clipboard, KernovaVsockPort.log,
            KernovaVsockPort.clipboardData,
        ]
        let ports = VsockFeatureDescriptor.all.map(\.port)

        #expect(Set(ports).count == ports.count)
        #expect(Set(ports).isSubset(of: registered))
    }

    /// Gating the control channel on the gate its own handshake fills would
    /// deadlock every session.
    @Test("Only the control channel skips the admission gate")
    func onlyControlSkipsAdmission() {
        #expect(VsockFeatureDescriptor.control.requirement == nil)
        #expect(VsockFeatureDescriptor.log.requirement != nil, "log: admits ungated")
        // Log forwarding asks for the handshake and nothing more.
        #expect(VsockFeatureDescriptor.log.requirement?.capability == nil)
    }

    @Test("Each descriptor's install-time gate tracks its own configuration flag")
    func isEnabledTracksItsFlag() {
        var config = VMConfiguration(
            name: "Gate VM", guestOS: .macOS, bootMode: .macOS, cpuCount: VMGuestOS.macOS.hostCPUCount,
            memorySizeInGB: VMGuestOS.macOS.hostMemorySize)
        config.agentLogForwardingEnabled = false

        // The control plane runs whatever the feature toggles say.
        #expect(VsockFeatureDescriptor.control.isEnabled(config))
        #expect(!VsockFeatureDescriptor.log.isEnabled(config))

        config.agentLogForwardingEnabled = true

        #expect(VsockFeatureDescriptor.log.isEnabled(config))
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
                == VsockFeatureDescriptor.all.map(\.port))
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

    @Test("stopAll settles every slot and clears the gate")
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
        instance.cancelAgentAbsenceWatchdog()
    }
}
