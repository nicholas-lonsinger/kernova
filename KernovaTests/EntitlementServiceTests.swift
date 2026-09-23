import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("EntitlementService", .admissionGated)
struct EntitlementServiceTests {
    @Test("hasVMNetworking is true exactly when the signature claims com.apple.vm.networking")
    func vmNetworkingReflectsReader() {
        #expect(
            EntitlementService(reader: MockEntitlementReader(granted: ["com.apple.vm.networking"]))
                .hasVMNetworking)
        #expect(!EntitlementService(reader: MockEntitlementReader()).hasVMNetworking)
        #expect(
            !EntitlementService(
                reader: MockEntitlementReader(granted: ["com.apple.security.app-sandbox"])
            ).hasVMNetworking)
    }

    @Test("hasAccessoryAccess is true exactly when the signature claims the accessory entitlement")
    func accessoryAccessReflectsReader() {
        #expect(
            EntitlementService(
                reader: MockEntitlementReader(
                    granted: ["com.apple.developer.accessory-access.usb"])
            ).hasAccessoryAccess)
        #expect(!EntitlementService(reader: MockEntitlementReader()).hasAccessoryAccess)
        // The two entitlements are read independently, so neither answers for
        // the other.
        #expect(
            !EntitlementService(reader: MockEntitlementReader(granted: ["com.apple.vm.networking"]))
                .hasAccessoryAccess)
    }

    @Test("hasTopologyObservation is true exactly when the signature claims the observation key")
    func topologyObservationReflectsReader() {
        let key = "com.apple.developer.networking.topology-observation"
        #expect(EntitlementService(reader: MockEntitlementReader(granted: [key])).hasTopologyObservation)
        #expect(!EntitlementService(reader: MockEntitlementReader()).hasTopologyObservation)
        #expect(
            !EntitlementService(reader: MockEntitlementReader(granted: ["com.apple.vm.networking"]))
                .hasTopologyObservation)
    }

    @Test("Observing guest addresses follows the observation key on macOS 27")
    func guestAddressObservationFollowsTheKey() {
        guard #available(macOS 27.0, *) else { return }
        let key = "com.apple.developer.networking.topology-observation"
        #expect(
            EntitlementService(reader: MockEntitlementReader(granted: [key]))
                .supportsGuestAddressObservation)
        #expect(!EntitlementService(reader: MockEntitlementReader()).supportsGuestAddressObservation)
    }

    @Test("The process reader reports an unclaimed key as absent")
    func processReaderUnclaimedKeyIsAbsent() {
        #expect(!ProcessEntitlementReader().hasEntitlement("app.kernova.test.never-claimed"))
    }
}
