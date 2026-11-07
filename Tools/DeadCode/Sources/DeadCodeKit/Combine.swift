import Foundation

/// One platform's Periphery report over one view of its build, and that platform's index as a `Presence`.
package struct PlatformScan: Sendable {
    package var platform: Platform
    package var findings: [Finding]
    /// Required when this scan is combined with another platform's.
    package var presence: Presence?

    package init(platform: Platform, findings: [Finding], presence: Presence?) {
        self.platform = platform
        self.findings = findings
        self.presence = presence
    }
}

/// How one platform sees a finding's location.
package enum PlatformState: Hashable, Sendable {
    /// The platform does not compile the location.
    case absent
    /// The platform compiles the location and reports nothing there, so something on it uses the code.
    case used
    /// The platform reports the location with these hints.
    case reported([String])
}

/// A finding no scanned platform uses.
package struct CombinedFinding: Hashable, Sendable {
    package var key: FindingKey
    package var kind: String
    package var name: String
    package var hints: [String]
    package var states: [Platform: PlatformState]

    /// The platforms that compile this finding's location, when that is not all of `platforms`.
    package func compiledOnly(among platforms: [Platform]) -> [Platform]? {
        let compiled = platforms.filter { states[$0] != .absent }
        return compiled.count < platforms.count ? compiled : nil
    }
}

package enum CombineError: Error, Equatable, CustomStringConvertible {
    case duplicatePlatform(Platform)
    case missingPresence(Platform)
    /// The platform reports locations its own presence lacks, so its presence does not describe its index.
    case unlistedFindings(Platform, [String])

    package var description: String {
        switch self {
        case .duplicatePlatform(let platform): "\(platform.displayName) is given twice"
        case .missingPresence(let platform):
            "\(platform.displayName) has no presence data, which combining it with another platform needs"
        case .unlistedFindings(let platform, let locations):
            "\(platform.displayName)'s presence lacks \(locations.count) of its own findings, so it does not describe "
                + "the index that was scanned: " + locations.prefix(5).joined(separator: ", ")
        }
    }
}

/// Combines one view's per-platform reports: a finding stands only where no platform uses it.
///
/// Each platform sees a finding's location as `absent`, `used` or reported. A finding any platform uses is dropped;
/// otherwise it carries the most-used hint the reporting platforms give, ranked unused < assign-only < every other
/// hint, and every hint of that rank when they differ. A protocol conformance stands when its protocol's
/// `redundantProtocol` finding does.
package func combine(_ scans: [PlatformScan]) throws(CombineError) -> [CombinedFinding] {
    var seen = Set<Platform>()
    for scan in scans where !seen.insert(scan.platform).inserted { throw .duplicatePlatform(scan.platform) }
    if scans.count > 1, let scan = scans.first(where: { $0.presence == nil }) {
        throw .missingPresence(scan.platform)
    }
    let scans = scans.sorted { $0.platform < $1.platform }

    var reported: [Platform: [FindingKey: Finding]] = [:]
    var conformances: [FindingKey: (finding: Finding, platforms: [Platform])] = [:]
    for scan in scans {
        var byKey: [FindingKey: Finding] = [:]
        for finding in scan.findings {
            let key = finding.key
            if finding.isConformance {
                conformances[key, default: (finding, [])].platforms.append(scan.platform)
            } else {
                byKey[key] = finding
            }
        }
        if let presence = scan.presence {
            let unlisted = byKey.keys.filter { !presence.contains($0) }.sorted()
            if !unlisted.isEmpty {
                throw .unlistedFindings(scan.platform, unlisted.compactMap { byKey[$0]?.location.description })
            }
        }
        reported[scan.platform] = byKey
    }

    var combined: [CombinedFinding] = []
    for key in Set(reported.values.flatMap(\.keys)).sorted() {
        var states: [Platform: PlatformState] = [:]
        var sample: Finding?
        for scan in scans {
            if let finding = reported[scan.platform]?[key] {
                states[scan.platform] = .reported(finding.hints)
                sample = sample ?? finding
            } else if scan.presence?.contains(key) == true {
                states[scan.platform] = .used
            } else {
                states[scan.platform] = .absent
            }
        }
        guard let sample, !states.values.contains(.used) else { continue }
        let hints = states.values.flatMap { state -> [String] in
            if case .reported(let hints) = state { return hints }
            return []
        }
        let top = hints.map(hintRank).max() ?? 0
        combined.append(
            CombinedFinding(
                key: key, kind: sample.kind, name: sample.name,
                hints: Set(hints.filter { hintRank($0) == top }).sorted(), states: states))
    }

    let redundantProtocols = Set(
        combined.filter { $0.hints.contains("redundantProtocol") }.flatMap { finding in
            scans.compactMap { reported[$0.platform]?[finding.key]?.ids }.flatMap { $0 }
        })
    for (key, entry) in conformances where !redundantProtocols.isDisjoint(with: entry.finding.ids) {
        var states: [Platform: PlatformState] = [:]
        for scan in scans {
            states[scan.platform] = entry.platforms.contains(scan.platform) ? .reported(entry.finding.hints) : .absent
        }
        combined.append(
            CombinedFinding(
                key: key, kind: entry.finding.kind, name: entry.finding.name, hints: entry.finding.hints,
                states: states))
    }
    return combined.sorted { $0.key < $1.key }
}

/// Unused < assign-only < used in some other way, so a combined finding says the most any platform's uses allow.
private func hintRank(_ hint: String) -> Int {
    switch hint {
    case "unused": 0
    case "assignOnlyProperty": 1
    default: 2
    }
}

/// The dead-code report: what no scanned platform uses at all, and what only tests reach.
package struct DeadCodeReport: Sendable {
    package var platforms: [Platform]
    /// Unused even counting the test targets.
    package var dead: [CombinedFinding]
    /// Reported with tests out of the build and not by the full scan: code whose only users are tests.
    package var testOnly: [CombinedFinding]

    package enum Verdict: String, Sendable {
        case clean
        case findings
        /// A platform is missing, so what only it uses is listed as dead.
        case partial
    }

    package var missingPlatforms: [Platform] {
        Platform.allCases.filter { !platforms.contains($0) }
    }

    package var verdict: Verdict {
        if !missingPlatforms.isEmpty { return .partial }
        return dead.isEmpty && testOnly.isEmpty ? .clean : .findings
    }

    /// Combines each platform's full scan (test targets built) and production scan (every target only tests reach
    /// excluded).
    package init(full: [PlatformScan], production: [PlatformScan]) throws(CombineError) {
        platforms = full.map(\.platform).sorted()
        dead = try combine(full)
        let deadHints = Dictionary(dead.map { ($0.key, $0.hints) }, uniquingKeysWith: { first, _ in first })
        testOnly = try combine(production).filter { deadHints[$0.key] != $0.hints }
    }
}
