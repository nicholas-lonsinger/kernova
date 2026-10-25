import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaVirtualization

@Suite("USBAccessorySupport Tests", .caseScoped)
@MainActor
struct USBAccessorySupportTests {
    @Test("On macOS 27 the signature decides, and its absence is named as the entitlement")
    @available(macOS 27.0, *)
    func theSignatureDecidesOnMacOS27() {
        #expect(USBAccessorySupport.passthrough(entitlements: .unentitled).gap == .needsEntitlement)
        #expect(USBAccessorySupport.passthrough(entitlements: .entitled).service != nil)
    }
}
