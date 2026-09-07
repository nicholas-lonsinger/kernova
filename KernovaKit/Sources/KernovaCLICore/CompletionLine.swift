import ArgumentParser
import Foundation

/// A command line a shell is part-way through typing, read back as the command
/// it stands for.
///
/// A value completion depends on what the rest of the line already said — the
/// virtual machine whose snapshots are being offered, whether `--id` is in
/// force. Re-parsing the line with the tool's own grammar is what answers that
/// without a second, drifting copy of which words are flags and which are
/// values.
enum CompletionLine {
    /// Stands in for the word being completed, and for any argument the line
    /// has not reached yet, so a half-typed line still parses.
    ///
    /// A control character: it has to be something no argument would carry and
    /// no shell can produce, so a caller can tell a real value from this one.
    static let placeholder = "\u{1}"

    /// How many arguments a line may still be missing and parse anyway.
    ///
    /// The longest verb takes three positionals (`snapshot rename`), so
    /// completing the first of them leaves two unwritten.
    private static let maximumUnwrittenArguments = 2

    /// The command `words` spells out, with the word at `index` replaced by
    /// ``placeholder`` and anything after it dropped.
    ///
    /// `words` is the whole line as the shell passed it, the tool's own name
    /// first; `index` is where in it the cursor sits. Arguments the line has
    /// not reached are filled with ``placeholder`` too, so completing the first
    /// of several still parses — a caller that needs one of them back checks
    /// for the placeholder itself.
    ///
    /// - Returns: `nil` for a line no padding makes parse, which is a line
    ///   whose completion has nothing to offer.
    static func command(from words: [String], completingAt index: Int) -> ParsableCommand? {
        let typed = Array(words.dropFirst().prefix(max(0, index - 1)))
        for unwritten in 0...maximumUnwrittenArguments {
            let line = typed + Array(repeating: placeholder, count: unwritten + 1)
            if let command = try? KernovaCommand.parseAsRoot(line) { return command }
        }
        return nil
    }

    /// Whether the line reads its virtual machine and snapshot arguments as
    /// identifiers rather than as display names.
    static func forcesIdentifiers(in words: [String], completingAt index: Int) -> Bool {
        let command = command(from: words, completingAt: index)
        return (command as? any GlobalOptionsCommand)?.options.id ?? false
    }

    /// The virtual machine whose snapshots the line is asking for, and whether
    /// it named that machine by identifier.
    ///
    /// - Returns: `nil` when the line is not one that addresses a snapshot, or
    ///   has not named the virtual machine yet.
    static func snapshotSubject(
        in words: [String], completingAt index: Int
    ) -> (vm: String, byIdentifier: Bool)? {
        guard let command = command(from: words, completingAt: index) as? any SnapshotCommandLine,
            command.vm != placeholder
        else { return nil }
        return (command.vm, command.options.id)
    }
}

/// A subcommand carrying the options every one of them takes.
///
/// Completion runs before any command does, so the flags that change what a
/// value *means* are read back off the parsed line through this rather than
/// re-derived from the raw words.
protocol GlobalOptionsCommand: ParsableCommand {
    /// The options every subcommand carries.
    var options: GlobalOptions { get }
}

/// A subcommand that names a virtual machine and one of its snapshots.
///
/// The snapshot argument is completed against that machine's own listing, so
/// the completion has to reach the machine the line already named.
protocol SnapshotCommandLine: GlobalOptionsCommand {
    /// Which virtual machine, as the line spells it.
    var vm: String { get }
}
