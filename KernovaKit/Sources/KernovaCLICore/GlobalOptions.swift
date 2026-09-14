import ArgumentParser
import Foundation

/// How output is written.
enum OutputFormat: String, ExpressibleByArgument, Sendable, CaseIterable {
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
struct GlobalOptions: ParsableArguments {
    /// How to write the answer.
    @Option(name: .long, help: "Output format: table or json.")
    var format: OutputFormat = .table

    /// Print the bare value a script wants and nothing else.
    @Flag(name: [.customShort("q"), .long], help: "Print only the values, with no headings.")
    var quiet = false

    /// Read the VM and snapshot arguments as identifiers, never as display
    /// names.
    @Flag(
        name: .long,
        help: "Read the virtual machine and snapshot arguments as identifiers only.")
    var id = false

    /// Supply the consent a destructive verb refuses without.
    @Flag(name: [.customShort("y"), .long], help: "Answer yes to the confirmation a verb asks for.")
    var yes = false

    /// Refuse rather than starting Kernova to answer.
    @Flag(name: .long, help: "Fail instead of starting Kernova when it is not running.")
    var noLaunch = false
}
