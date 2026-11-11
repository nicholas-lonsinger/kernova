import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("BridgedInterfaceSelection Tests", .caseScoped)
struct BridgedInterfaceSelectionTests {
    @Test("A primary interface that isn't bridgeable resolves to nothing")
    func unbridgeablePrimaryResolvesToNil() {
        #expect(
            BridgedInterfaceSelection.choose(
                persisted: nil, available: ["en2", "en3"], primary: "utun4") == nil)
        #expect(
            BridgedInterfaceSelection.choose(
                persisted: "en5", available: ["en2", "en3"], primary: nil) == nil)
    }
}
