import ArgumentParser
import Foundation

/// How output is written.
public enum OutputFormat: String, ExpressibleByArgument, Sendable, CaseIterable {
    /// Column-aligned text for a person.
    case table
    /// The wire DTOs encoded as JSON, for a script.
    case json
}

/// The options every subcommand carries.
///
/// One group rather than per-command flags, so `--format`, `--quiet` and the
/// rest mean the same thing everywhere and a script never has to remember
/// which verb accepts which.
public struct GlobalOptions: ParsableArguments {
    /// How to write the answer.
    @Option(name: .long, help: "Output format: table or json.")
    public var format: OutputFormat = .table

    /// Print the bare value a script wants and nothing else.
    @Flag(name: [.customShort("q"), .long], help: "Print only the values, with no headings.")
    public var quiet = false

    /// Read the VM argument as an identifier, never as a display name.
    @Flag(name: .long, help: "Read the virtual machine argument as an identifier only.")
    public var id = false

    /// Refuse rather than launching Kernova to answer.
    @Flag(name: .customLong("no-launch"), help: "Fail instead of launching Kernova.")
    public var noLaunch = false

    /// Supply the consent a destructive verb refuses without.
    @Flag(name: [.customShort("y"), .long], help: "Answer yes to the confirmation a verb asks for.")
    public var yes = false

    /// Creates the group with every option at its default.
    public init() {}
}
