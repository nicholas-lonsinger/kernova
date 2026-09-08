import ArgumentParser
import Foundation
import KernovaKit

extension KernovaCommand {
    /// `kernova forward` — a virtual machine's host→guest port mappings.
    public struct Forward: ParsableCommand {
        /// What `kernova forward --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "forward",
            abstract: "Work with a virtual machine's forwarded ports.",
            discussion: "Each mapping is written <host-port>:<guest-port>, and covers TCP unless "
                + "--udp says otherwise. A host port is claimed across every virtual machine on "
                + "the network, so one another rule already forwards is refused.",
            subcommands: [List.self, Add.self, Remove.self])

        /// Creates the parent command; a bare `kernova forward` prints this
        /// help.
        public init() {}
    }
}

extension KernovaCommand.Forward {
    /// `kernova forward list <vm>` — every mapping the virtual machine carries.
    public struct List: VerbCommand {
        /// What `kernova forward list --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List a virtual machine's forwarded ports.",
            discussion: "Each rule prints as the <host-port>:<guest-port> mapping `forward "
                + "remove` takes back, beside the transport it covers. A rule is listed whether "
                + "or not the network carrying it is declared right now.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// The request this command line stands for.
        public func verb() throws -> VMCommandRequest.Verb {
            .portForwardingRules(try SelectorParsing.selector(from: vm, forcingID: options.id))
        }

        /// Reads the rules and writes them.
        public func run() throws {
            let answered = try answer()
            guard case .portForwardingRules(let rules) = answered else {
                throw answered.unexpectedAnswer
            }
            Console.out(
                options.format == .json
                    ? try JSONRenderer.render(rules)
                    : TableRenderer.render(rules, quiet: options.quiet))
        }
    }

    /// `kernova forward add <vm> <host-port>:<guest-port>` — publish a guest
    /// port on this Mac.
    public struct Add: VerbCommand {
        /// What `kernova forward add --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Forward a host port to a guest port.",
            discussion: "The rule is carried by the network the virtual machine is joined to, "
                + "so it takes effect the next time that network is declared.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String

        /// The mapping to add, written `<host-port>:<guest-port>`.
        @Argument(help: "The mapping to add, as <host-port>:<guest-port>.")
        public var mapping: String

        /// Forward UDP rather than TCP.
        @Flag(name: .long, help: "Forward UDP rather than TCP.")
        public var udp = false

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// The request this command line stands for.
        public func verb() throws -> VMCommandRequest.Verb {
            .editPortForwarding(
                try SelectorParsing.selector(from: vm, forcingID: options.id),
                .add(rule: try PortMapping.rule(from: mapping, transport: udp ? .udp : .tcp)))
        }

        /// Adds the rule.
        public func run() throws {
            try perform()
        }
    }

    /// `kernova forward remove <vm> <host-port>:<guest-port>` — stop
    /// publishing one.
    public struct Remove: VerbCommand, VMScopedCommandLine {
        /// What `kernova forward remove --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Stop forwarding a host port to a guest port.",
            discussion: "A network carries one rule per transport and host port, so the host "
                + "half of the mapping is what names the rule to drop. One the virtual machine "
                + "does not carry exits 2.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String

        /// The mapping to drop, written `<host-port>:<guest-port>`.
        @Argument(
            help: "The mapping to drop, as <host-port>:<guest-port>.",
            completion: CompletionSource.portMapping)
        public var mapping: String

        /// Drop a UDP rule rather than a TCP one.
        @Flag(name: .long, help: "Drop the UDP rule rather than the TCP one.")
        public var udp = false

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// The request this command line stands for.
        public func verb() throws -> VMCommandRequest.Verb {
            .editPortForwarding(
                try SelectorParsing.selector(from: vm, forcingID: options.id),
                .remove(
                    claim: try PortMapping.rule(from: mapping, transport: udp ? .udp : .tcp)
                        .hostClaim))
        }

        /// Drops the rule.
        public func run() throws {
            try perform()
        }
    }
}

/// How the tool reads and writes a `<host-port>:<guest-port>` argument.
enum PortMapping {
    /// `rule` written the way an argument spells one.
    ///
    /// The inverse of ``rule(from:transport:)``, so what the tool prints and
    /// completes is what it parses back.
    static func text(for rule: PortForwardingRule) -> String {
        "\(rule.hostPort):\(rule.guestPort)"
    }

    /// The rule `text` names on `transport`.
    ///
    /// - Throws: ``CLIFailure`` with ``CLIExitCode/usage`` when `text` is not a
    ///   pair of ports a service can answer on.
    static func rule(
        from text: String, transport: PortForwardingTransport
    ) throws -> PortForwardingRule {
        let halves = text.split(separator: ":", omittingEmptySubsequences: false)
        guard halves.count == 2 else {
            throw CLIFailure(
                .usage,
                "\u{201C}\(text)\u{201D} is not a <host-port>:<guest-port> mapping.")
        }
        return PortForwardingRule(
            transport: transport,
            hostPort: try port(String(halves[0]), of: text),
            guestPort: try port(String(halves[1]), of: text))
    }

    /// One half of a mapping as a port number.
    ///
    /// Refuses rather than clamping, and refuses port 0 with everything else
    /// outside the range: it addresses no service, so a rule naming it would
    /// forward nothing.
    private static func port(_ text: String, of mapping: String) throws -> UInt16 {
        let range = PortForwardingRule.portRange
        guard let value = Int(text), range.contains(value) else {
            throw CLIFailure(
                .usage,
                "\u{201C}\(mapping)\u{201D} names \u{201C}\(text)\u{201D}, which is not a port "
                    + "between \(range.lowerBound) and \(range.upperBound).")
        }
        return UInt16(value)
    }
}
