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
        let typed = words.dropFirst().prefix(max(0, index - 1)).map(dequoted)
        for unwritten in 0...maximumUnwrittenArguments {
            let line = typed + Array(repeating: placeholder, count: unwritten + 1)
            if let command = try? KernovaCommand.parseAsRoot(line) { return command }
        }
        return nil
    }

    /// `word` with the quoting a shell removes before a command sees it.
    ///
    /// Shells hand a custom completion their words verbatim, quotes and
    /// escapes intact. A virtual machine called `Alpha Copy` — the name every
    /// clone is given — is typed `'Alpha Copy'`, and a selector built from that
    /// word with its quotes still on matches nothing.
    ///
    /// Enough of the grammar to undo what a user types: single quotes take
    /// everything literally, double quotes and a bare backslash escape the
    /// character after them.
    static func dequoted(_ word: String) -> String {
        var result = ""
        var openQuote: Character?
        var escaped = false
        for character in word {
            if escaped {
                result.append(character)
                escaped = false
                continue
            }
            if character == "\\", openQuote != "'" {
                escaped = true
                continue
            }
            if let open = openQuote {
                if character == open { openQuote = nil } else { result.append(character) }
                continue
            }
            if character == "'" || character == "\"" {
                openQuote = character
                continue
            }
            result.append(character)
        }
        return result
    }

    /// Whether the line reads its virtual machine and snapshot arguments as
    /// identifiers rather than as display names.
    static func forcesIdentifiers(in words: [String], completingAt index: Int) -> Bool {
        let command = command(from: words, completingAt: index)
        return (command as? any GlobalOptionsCommand)?.options.id ?? false
    }

    /// Whether the word being completed is a `set` assignment's value rather
    /// than the key in front of it.
    ///
    /// Two shapes, because bash holds `=` in `COMP_WORDBREAKS` and splits
    /// `cpus=` into three words: the `=` is either still inside the word the
    /// cursor sits in, or it is the whole word behind it.
    static func isPastAnAssignmentKey(
        in words: [String], completingAt index: Int, prefix: String
    ) -> Bool {
        if prefix.contains("=") { return true }
        return words.indices.contains(index - 1) && words[index - 1] == "="
    }

    /// The virtual machine the line is asking about something of, the command
    /// asking, and whether the machine was named by identifier.
    ///
    /// The command comes back with the machine because a completion may need
    /// more of the line than the machine — which transport a `forward remove`
    /// named, say.
    ///
    /// - Returns: `nil` when the line is not one that names a virtual machine
    ///   alongside something of that machine's own, or has not named the
    ///   machine yet.
    static func vmSubject(
        in words: [String], completingAt index: Int
    ) -> (command: any VMScopedCommandLine, vm: String, byIdentifier: Bool)? {
        guard let command = command(from: words, completingAt: index) as? any VMScopedCommandLine,
            command.vm != placeholder
        else { return nil }
        return (command, command.vm, command.options.id)
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

/// A subcommand that names a virtual machine and something the machine itself
/// carries — one of its snapshots, a folder it shares, a port it forwards.
///
/// That second argument is completed against the machine's own listing, so the
/// completion has to reach the machine the line already named.
protocol VMScopedCommandLine: GlobalOptionsCommand {
    /// Which virtual machine, as the line spells it.
    var vm: String { get }
}
