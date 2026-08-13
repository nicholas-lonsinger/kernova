import Testing

@testable import Kernova

@Suite("EntitlementService")
struct EntitlementServiceTests {
    private struct FakeReader: EntitlementReading {
        let granted: Set<String>
        func hasEntitlement(_ key: String) -> Bool { granted.contains(key) }
    }

    @Test("hasVMNetworking is true exactly when the signature claims com.apple.vm.networking")
    func vmNetworkingReflectsReader() {
        #expect(
            EntitlementService(reader: FakeReader(granted: ["com.apple.vm.networking"]))
                .hasVMNetworking)
        #expect(!EntitlementService(reader: FakeReader(granted: [])).hasVMNetworking)
        #expect(
            !EntitlementService(reader: FakeReader(granted: ["com.apple.security.app-sandbox"]))
                .hasVMNetworking)
    }

    @Test("The process reader reports an unclaimed key as absent")
    func processReaderUnclaimedKeyIsAbsent() {
        #expect(!ProcessEntitlementReader().hasEntitlement("app.kernova.test.never-claimed"))
    }
}
