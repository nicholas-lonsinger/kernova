import Testing

@testable import Kernova

@Suite("BridgedInterfaceSelection Tests", .admissionGated)
struct BridgedInterfaceSelectionTests {
    @Test("A persisted interface that is still available wins over the primary one")
    func persistedAvailableWins() {
        #expect(
            BridgedInterfaceSelection.choose(
                persisted: "en1", available: ["en0", "en1"], primary: "en0") == "en1")
    }

    @Test("A persisted interface the host no longer offers falls back to the primary one")
    func persistedAbsentFallsBackToPrimary() {
        #expect(
            BridgedInterfaceSelection.choose(
                persisted: "en5", available: ["en0", "en1"], primary: "en1") == "en1")
    }

    @Test("Automatic resolves to the primary interface")
    func automaticResolvesToPrimary() {
        #expect(
            BridgedInterfaceSelection.choose(
                persisted: nil, available: ["en0", "en1"], primary: "en1") == "en1")
    }

    @Test("A primary interface that isn't bridgeable resolves to nothing")
    func unbridgeablePrimaryResolvesToNil() {
        #expect(
            BridgedInterfaceSelection.choose(
                persisted: nil, available: ["en2", "en3"], primary: "utun4") == nil)
        #expect(
            BridgedInterfaceSelection.choose(
                persisted: "en5", available: ["en2", "en3"], primary: nil) == nil)
    }

    @Test("No bridgeable interfaces resolves to nothing")
    func emptyAvailableResolvesToNil() {
        #expect(
            BridgedInterfaceSelection.choose(persisted: "en0", available: [], primary: "en0") == nil)
        #expect(BridgedInterfaceSelection.choose(persisted: nil, available: [], primary: nil) == nil)
    }
}
