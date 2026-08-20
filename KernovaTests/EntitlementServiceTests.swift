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

    @Test("The process reader reports an unclaimed key as absent")
    func processReaderUnclaimedKeyIsAbsent() {
        #expect(!ProcessEntitlementReader().hasEntitlement("app.kernova.test.never-claimed"))
    }
}
