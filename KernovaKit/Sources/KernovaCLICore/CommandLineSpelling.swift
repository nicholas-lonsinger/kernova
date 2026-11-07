import Foundation
import KernovaCommandModel

/// How a request is spelled as a `kernova` command line a shell runs.
enum CommandLineSpelling {
    /// `text` as one shell word: bare when every character is one a shell
    /// reads literally, else single-quoted.
    static func word(_ text: String) -> String {
        let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-=:/"))
        let bare = !text.isEmpty && text.unicodeScalars.allSatisfy(wordCharacters.contains)
        guard !bare else { return text }
        return "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The `kernova` command line of `words`, each spelled as one shell word.
    static func line(_ words: [String]) -> String {
        "kernova " + words.map(word).joined(separator: " ")
    }

    /// The command line that takes `step`.
    static func line(for step: CommandStep) -> String {
        switch step {
        case .resume(let vm): line(["resume", vm.name])
        case .discardSavedState(let vm): line(["stop", vm.name, "--yes"])
        case .setConfiguration(let vm, let assignments):
            line(["set", vm.name] + assignments.map { "\($0.key)=\($0.value)" })
        }
    }

    /// The command line that takes `ending`, `nil` for the refused one asked
    /// again, which the caller just typed.
    static func line(for ending: StepRoute.Ending) -> String? {
        switch ending {
        case .refusedVerb: nil
        case .start(let vm): line(["start", vm.name])
        }
    }

    /// What the tool prints for `notice`.
    ///
    /// The baseline's command line ends in a placeholder for the snapshot the
    /// user has yet to take; `ephemeral.baseline` takes its name or
    /// identifier.
    static func message(for notice: VMCommandNotice) -> String {
        switch notice {
        case .ephemeralRevert(let vm, let baseline):
            "Ephemeral Mode is on for \u{201C}\(vm.name)\u{201D}: this change goes back to "
                + "\u{201C}\(baseline.name)\u{201D} at the next shutdown. To keep it, take a "
                + "snapshot (\(line(["snapshot", "take", vm.name]))) and choose it as the baseline "
                + "(\(line(["set", vm.name])) ephemeral.baseline=<snapshot>)."
        }
    }

    /// Each of `requirement`'s routes as the command lines that take it, its
    /// ending's last: a one-line route on its title's line, a longer one
    /// beneath it, a line each.
    static func routes(of requirement: StepRequirement) -> String {
        requirement.routes.map { route in
            let lines = route.steps.map(line(for:)) + [line(for: route.ending)].compactMap(\.self)
            guard lines.count != 1 else { return "\(route.title) with: \(lines[0])" }
            return "\(route.title) with:" + lines.map { "\n  " + $0 }.joined()
        }.joined(separator: "\n")
    }
}
