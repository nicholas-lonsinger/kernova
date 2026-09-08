import Foundation
import KernovaKit
import Testing

@testable import KernovaCLICore

/// What the configuration verbs actually put on the wire, and what they do with
/// the answer, against a real socket.
@Suite("CLI configuration wire", .admissionGated)
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

        let everything = try CLIWire.exchange(["get", "Alpha"], answering: answered, tag: "get-all")
        #expect(everything.sent == [.configuration(.idOrName("Alpha"), keys: nil)])
        #expect(try everything.answer.payload() == .configuration(settings))

        let named = try CLIWire.exchange(
            ["get", "Alpha", "memory", "cpus"], answering: answered, tag: "get-named")
        #expect(named.sent == [.configuration(.idOrName("Alpha"), keys: ["memory", "cpus"])])
    }

    @Test("get --keys asks for the keyspace, which names no virtual machine")
    func getKeysAsksForTheKeyspace() throws {
        let keyspace = [
            ConfigurationKeyDescriptor(
                name: "cpus", summary: "Virtual CPU cores.", editableWhileRunning: false)
        ]
        let exchanged = try CLIWire.exchange(
            ["get", "--keys"], answering: VMCommandResponse(result: .configurationKeys(keyspace)),
            tag: "get-keys")

        #expect(exchanged.sent == [.configurationKeys])
        #expect(try exchanged.answer.payload() == .configurationKeys(keyspace))
    }

    // MARK: - Writes

    @Test("A set crosses as one request carrying every assignment, in the order typed")
    func setSendsOneRequestForEveryAssignment() throws {
        let exchanged = try CLIWire.exchange(
            ["set", "Alpha", "cpus=4", "memory=8"],
            answering: VMCommandResponse(result: .configuration(settings)), tag: "set")

        // One request, not one per assignment: the app applies them together or
        // not at all, which a second round trip would give up.
        #expect(
            exchanged.sent == [
                .setConfiguration(.idOrName("Alpha"), assignments: settings, confirmed: false)
            ])
        #expect(try exchanged.answer.payload() == .configuration(settings))
    }

    @Test("--yes crosses as the consent the one gated setting asks for")
    func setCarriesConsentAcrossTheWire() throws {
        let passthrough = [ConfigurationEntry(key: "clipboard.passthrough", value: "true")]
        let exchanged = try CLIWire.exchange(
            ["set", "Alpha", "clipboard.passthrough=true", "--yes"],
            answering: VMCommandResponse(result: .configuration(passthrough)), tag: "set-yes")

        #expect(
            exchanged.sent == [
                .setConfiguration(.idOrName("Alpha"), assignments: passthrough, confirmed: true)
            ])
    }

    @Test("A set the app will not do without consent says how to give it")
    func setWithoutConsentReportsHowToGiveIt() throws {
        let exchanged = try CLIWire.exchange(
            ["set", "Alpha", "clipboard.passthrough=true"],
            answering: VMCommandResponse(
                result: .failure(
                    .confirmationRequired(
                        prompt: ConfirmationPrompt(
                            kind: .enableClipboardPassthrough,
                            title: "Turn On Automatic Clipboard Passthrough?",
                            message: "\u{201C}Alpha\u{201D} will read whatever you copy.",
                            confirmTitle: "Turn On", dismissTitle: "Cancel")))),
            tag: "set-consent")

        do {
            _ = try exchanged.answer.payload()
            Issue.record("expected a confirmation refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == .refusedByState)
            #expect(failure.message.contains("will read whatever you copy"))
            #expect(failure.message.hasSuffix("Pass --yes to do it anyway."))
        }
    }

    @Test("A key or value the app will not take exits 2, carrying its whole refusal")
    func aRefusedArgumentExitsTwo() throws {
        let refusal = "There is no setting called \u{201C}cpu\u{201D}."
        let exchanged = try CLIWire.exchange(
            ["set", "Alpha", "cpu=4"],
            answering: VMCommandResponse(result: .failure(.invalidArgument(message: refusal))),
            tag: "set-bad-key")

        do {
            _ = try exchanged.answer.payload()
            Issue.record("expected an argument refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == .usage)
            #expect(failure.message == refusal)
        }
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
            answering: VMCommandResponse(result: .sharedDirectories(shares)), tag: "share-list")

        #expect(named.sent == [.sharedDirectories(.idOrName("Alpha"))])
        #expect(try named.answer.payload() == .sharedDirectories(shares))

        let identified = try CLIWire.exchange(
            ["share", "list", identifier.uuidString, "--id"],
            answering: VMCommandResponse(result: .sharedDirectories(shares)),
            tag: "share-list-id")
        #expect(identified.sent == [.sharedDirectories(.id(identifier))])
    }

    @Test("A share add crosses with the folder's absolute path and how it mounts")
    func shareAddSendsThePathAndItsAccess() throws {
        let exchanged = try CLIWire.exchange(
            ["share", "add", "Alpha", "/tmp/Work", "--read-only"],
            answering: VMCommandResponse(result: .ok), tag: "share-add")

        #expect(
            exchanged.sent == [
                .editSharedDirectory(.idOrName("Alpha"), .add(path: "/tmp/Work", readOnly: true))
            ])
        #expect(try exchanged.answer.payload() == .ok)
    }

    @Test("A share remove names the path rather than an identifier the caller has no way to hold")
    func shareRemoveSendsThePath() throws {
        let exchanged = try CLIWire.exchange(
            ["share", "remove", "Alpha", "/tmp/Work"],
            answering: VMCommandResponse(result: .ok), tag: "share-remove")

        #expect(
            exchanged.sent == [
                .editSharedDirectory(.idOrName("Alpha"), .removePath(path: "/tmp/Work"))
            ])
    }

    // MARK: - Forwarding

    @Test("A forward list asks for the rules of the virtual machine its argument names")
    func forwardListSendsTheSelector() throws {
        let rules = [
            PortForwardingRule(transport: .tcp, hostPort: 8080, guestPort: 80),
            PortForwardingRule(transport: .udp, hostPort: 5353, guestPort: 53),
        ]
        let named = try CLIWire.exchange(
            ["forward", "list", "Alpha"],
            answering: VMCommandResponse(result: .portForwardingRules(rules)),
            tag: "forward-list")

        #expect(named.sent == [.portForwardingRules(.idOrName("Alpha"))])
        #expect(try named.answer.payload() == .portForwardingRules(rules))

        let identified = try CLIWire.exchange(
            ["forward", "list", identifier.uuidString, "--id"],
            answering: VMCommandResponse(result: .portForwardingRules(rules)),
            tag: "forward-list-id")
        #expect(identified.sent == [.portForwardingRules(.id(identifier))])
    }

    @Test("A forward add crosses as a rule on the transport the flags chose")
    func forwardAddSendsTheRule() throws {
        let tcp = try CLIWire.exchange(
            ["forward", "add", "Alpha", "8080:80"], answering: VMCommandResponse(result: .ok),
            tag: "forward-tcp")
        #expect(
            tcp.sent == [
                .editPortForwarding(
                    .idOrName("Alpha"),
                    .add(rule: PortForwardingRule(transport: .tcp, hostPort: 8080, guestPort: 80)))
            ])

        let udp = try CLIWire.exchange(
            ["forward", "add", "Alpha", "5353:53", "--udp"],
            answering: VMCommandResponse(result: .ok), tag: "forward-udp")
        #expect(
            udp.sent == [
                .editPortForwarding(
                    .idOrName("Alpha"),
                    .add(rule: PortForwardingRule(transport: .udp, hostPort: 5353, guestPort: 53)))
            ])
    }

    @Test("A forward remove crosses as the host-side claim that identifies the rule")
    func forwardRemoveSendsTheClaim() throws {
        let exchanged = try CLIWire.exchange(
            ["forward", "remove", "Alpha", "8080:80"], answering: VMCommandResponse(result: .ok),
            tag: "forward-remove")

        #expect(
            exchanged.sent == [
                .editPortForwarding(
                    .idOrName("Alpha"),
                    .remove(claim: PortForwardingHostClaim(transport: .tcp, hostPort: 8080)))
            ])
    }

    // MARK: - Answers

    @Test("An answer of the wrong shape refuses rather than being printed as settings")
    func anUnexpectedAnswerRefuses() {
        do {
            try ConfigurationOutput.write(.ok, options: GlobalOptions())
            Issue.record("expected an unavailable refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == .unavailable)
        } catch {
            Issue.record("expected a CLIFailure, got \(error)")
        }
    }
}
