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

    /// The command line that takes `step`.
    static func line(for step: CommandStep) -> String {
        let words: [String] =
            switch step {
            case .resume(let vm): ["resume", vm.name]
            case .discardSavedState(let vm): ["stop", vm.name, "--yes"]
            case .setConfiguration(let vm, let assignments):
                ["set", vm.name] + assignments.map { "\($0.key)=\($0.value)" }
            }
        return "kernova " + words.map(word).joined(separator: " ")
    }

    /// The command line that takes `ending`, `nil` for the refused one asked
    /// again, which the caller just typed.
    static func line(for ending: StepRoute.Ending) -> String? {
        switch ending {
        case .refusedVerb: nil
        case .start(let vm): "kernova " + ["start", vm.name].map(word).joined(separator: " ")
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
