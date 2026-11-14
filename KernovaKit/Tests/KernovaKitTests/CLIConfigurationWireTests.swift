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

    /// A virtual machine identifier, for the lines that force one with `--id`.
    private let identifier =
        UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID()

    // MARK: - Reads

    @Test("A bare get asks for every key, and a named one asks for those")
    func getAsksForTheKeysItWasGiven() throws {
        let answered = VMCommandResponse(result: .configuration(settings))

        let everything = try CLIWire.exchange(["get", "Alpha"], answering: answered)
        #expect(everything.sent == [.configuration(.idOrName("Alpha"), keys: nil)])
        #expect(try everything.answer.payload() == .configuration(settings))

        let named = try CLIWire.exchange(
            ["get", "Alpha", "memory", "cpus"], answering: answered)
        #expect(named.sent == [.configuration(.idOrName("Alpha"), keys: ["memory", "cpus"])])
    }

    // MARK: - Writes

    @Test("A set crosses as one request carrying every assignment, in the order typed")
    func setSendsOneRequestForEveryAssignment() throws {
        let exchanged = try CLIWire.exchange(
            ["set", "Alpha", "cpus=4", "memory=8"],
            answering: VMCommandResponse(result: .configuration(settings)))

        // One request, not one per assignment: the app applies them together or
        // not at all, which a second round trip would give up.
        #expect(
            exchanged.sent == [
                .setConfiguration(.idOrName("Alpha"), assignments: settings, consent: .none)
            ])
        #expect(try exchanged.answer.payload() == .configuration(settings))
    }

    // MARK: - Shares

    @Test("A share list asks for the folders of the virtual machine its argument names")
    func shareListSendsTheSelector() throws {
        let shares = [
            SharedDirectorySummary(path: "/tmp/Work", readOnly: false),
            SharedDirectorySummary(path: "/tmp/Reference", readOnly: true),
        ]
        let named = try CLIWire.exchange(
            ["share", "list", "Alpha"],
            answering: VMCommandResponse(result: .sharedDirectories(shares)))

        #expect(named.sent == [.sharedDirectories(.idOrName("Alpha"))])
        #expect(try named.answer.payload() == .sharedDirectories(shares))

        let identified = try CLIWire.exchange(
            ["share", "list", identifier.uuidString, "--id"],
            answering: VMCommandResponse(result: .sharedDirectories(shares)))
        #expect(identified.sent == [.sharedDirectories(.id(identifier))])
    }
}
