import Foundation

extension DeadCodeReport {
    /// What a terminal shows: a partial report opens by saying which platforms' uses it lacks, then `remedy`, what
    /// supplies them here, when there is one.
    package func text(remedy: String? = nil) -> String {
        var lines: [String] = []
        if !missingPlatforms.isEmpty {
            let scanned = platforms.map(\.displayName).joined(separator: " and ")
            let missing = missingPlatforms.map(\.displayName).joined(separator: " and ")
            lines.append(
                "This scan covers \(scanned) uses only. \(missing) was not scanned, so a symbol only \(missing) code "
                    + "uses is listed here as dead.")
            if let remedy { lines.append(remedy) }
            lines += [
                "The combined scan runs in CI: push the branch, run `gh workflow run dead-code.yml --ref <branch>`, "
                    + "and read the run's dead-code-report artifact.",
                "",
            ]
        }
        lines.append("\(deadTitle) (\(dead.count))")
        lines += section(dead).map { "  " + $0 }
        lines.append("")
        lines.append("Reached only by tests (\(testOnly.count))")
        lines += section(testOnly).map { "  " + $0 }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The tracker issue's two sections, each in a collapsed block, within `limit` characters: GitHub refuses an
    /// issue body over 65,536. When the lists do not fit, each keeps its first findings and names where the rest are.
    package func markdown(limit: Int, rest: String) -> String {
        let deadLines = section(dead)
        let testOnlyLines = section(testOnly)
        let whole = markdown(deadLines[...], testOnlyLines[...], rest: rest)
        guard whole.count > limit else { return whole }
        var low = 0
        var high = max(deadLines.count, testOnlyLines.count)
        while low < high {
            let mid = (low + high + 1) / 2
            if markdown(deadLines.prefix(mid), testOnlyLines.prefix(mid), rest: rest).count <= limit {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return markdown(deadLines.prefix(low), testOnlyLines.prefix(low), rest: rest)
    }

    private var deadTitle: String {
        missingPlatforms.isEmpty ? "Dead on every platform" : "Dead in the \(platformNames) scan"
    }

    private var platformNames: String { platforms.map(\.displayName).joined(separator: " and ") }

    private func markdown(_ dead: ArraySlice<String>, _ testOnly: ArraySlice<String>, rest: String) -> String {
        [
            block(title: "\(deadTitle) (\(self.dead.count))", lines: dead, total: section(self.dead).count, rest: rest),
            block(
                title: "Reached only by tests (\(self.testOnly.count))", lines: testOnly,
                total: section(self.testOnly).count, rest: rest),
        ].joined(separator: "\n")
    }

    private func block(title: String, lines: ArraySlice<String>, total: Int, rest: String) -> String {
        var body = ["<details><summary>\(title)</summary>", "", "```"] + lines + ["```"]
        if lines.count < total {
            body += ["", "The list stops after \(lines.count) of its \(total) lines; the rest are in \(rest)."]
        }
        return (body + ["", "</details>", ""]).joined(separator: "\n")
    }

    /// One line per file, then one indented line per finding in it: `line:column hint kind 'name'`, and the
    /// platforms that compile it when not every scanned one does.
    private func section(_ findings: [CombinedFinding]) -> [String] {
        var lines: [String] = []
        var file: String?
        for finding in findings {
            if finding.key.path != file {
                file = finding.key.path
                lines.append(finding.key.path)
            }
            let position =
                switch finding.key {
                case .declaration(_, let line, let column): "\(line):\(column)"
                case .importStatement(_, let line, _): "\(line)"
                }
            var line = "  \(position) \(finding.hints.joined(separator: ", ")) \(finding.kind) '\(finding.name)'"
            if let only = finding.compiledOnly(among: platforms) {
                line += " [\(only.map(\.displayName).joined(separator: ", ")) only]"
            }
            lines.append(line)
        }
        return lines
    }

    /// `dead=`, `test_only=` and `verdict=` lines, the form a GitHub Actions step output takes.
    package var summary: String {
        "dead=\(dead.count)\ntest_only=\(testOnly.count)\nverdict=\(verdict.rawValue)\n"
    }

    /// Both lists with each platform's state, for a reader comparing runs or chasing one finding.
    package func json() throws -> Data {
        func entries(_ findings: [CombinedFinding]) -> [[String: Any]] {
            findings.map { finding in
                var states: [String: String] = [:]
                for (platform, state) in finding.states {
                    states[platform.rawValue] =
                        switch state {
                        case .absent: "absent"
                        case .used: "used"
                        case .reported(let hints): hints.joined(separator: ",")
                        }
                }
                let location =
                    switch finding.key {
                    case .declaration(let path, let line, let column): "\(path):\(line):\(column)"
                    case .importStatement(let path, let line, _): "\(path):\(line)"
                    }
                return [
                    "location": location, "kind": finding.kind, "name": finding.name, "hints": finding.hints,
                    "platforms": states,
                ]
            }
        }
        let object: [String: Any] = [
            "platforms": platforms.map(\.rawValue),
            "verdict": verdict.rawValue,
            "dead": entries(dead),
            "testOnly": entries(testOnly),
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
