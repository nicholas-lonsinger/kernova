import Testing

@testable import Kernova

@Suite("EntitlementService", .caseScoped)
struct EntitlementServiceTests {
    @Test("Observing guest addresses follows the observation key on macOS 27")
    func guestAddressObservationFollowsTheKey() {
        guard #available(macOS 27.0, *) else { return }
        #expect(
            EntitlementService(
                hasVMNetworking: false, hasAccessoryAccess: false, hasTopologyObservation: true
            ).supportsGuestAddressObservation)
        #expect(!EntitlementService.unentitled.supportsGuestAddressObservation)
    }

    @Test("The process reader reports an unclaimed key as absent")
    func processReaderUnclaimedKeyIsAbsent() {
        #expect(!EntitlementService.processClaims("app.kernova.test.never-claimed"))
    }
}
