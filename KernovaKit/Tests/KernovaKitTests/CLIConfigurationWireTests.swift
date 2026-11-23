import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// What the configuration verbs actually put on the wire, and what they do with
/// the answer, against a real socket.
@Suite("CLI configuration wire", .caseScoped)
struct CLIConfigurationWireTests {
    private let settings = [
        ConfigurationEntry(key: "cpus", value: "4"),
        ConfigurationEntry(key: "memory", value: "8"),
    ]

    // MARK: - Reads

    @Test("A bare get asks for every key, and a named one asks for those")
    func getAsksForTheKeysItWasGiven() async throws {
        let answered = VMCommandResponse(result: .configuration(settings))

        let everything = try await CLIWire.exchange(["get", "Alpha"], answering: answered)
        #expect(everything.sent == [.configuration(.idOrName("Alpha"), keys: nil)])
        #expect(try everything.answer.payload() == .configuration(settings))

        let named = try await CLIWire.exchange(
            ["get", "Alpha", "memory", "cpus"], answering: answered)
        #expect(named.sent == [.configuration(.idOrName("Alpha"), keys: ["memory", "cpus"])])
    }
}
