import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// What the name rule gives a list of siblings, judged by what Cocoa
/// Scripting's own matcher relates: `caseInsensitiveCompare(_:)`, by which a
/// script's range and relative forms find an element by name.
@Suite("Name rule", .caseScoped)
struct NameRuleTests {
    /// Whether Cocoa's matcher finds either name the other.
    private static func cocoaRelates(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame || rhs.caseInsensitiveCompare(lhs) == .orderedSame
    }

    /// Whether a sibling may go by `name` whatever else does: trimmed, holding
    /// more than whitespace, and spelling no identifier.
    private static func isWellFormed(_ name: String) -> Bool {
        !name.isEmpty && name.trimmingCharacters(in: .whitespacesAndNewlines) == name
            && UUID(uuidString: name) == nil
    }

    /// What stored names are drawn from: case variants, a name a later
    /// duplicate's first free name would land on, untrimmed and empty names,
    /// the Greek pair Cocoa's matcher relates one way only, and an identifier
    /// in either case.
    private static let alphabet: [String] = {
        let identifier = "6F1D7E2C-0000-4000-8000-0000000000AA"
        return [
            "Build", "build", "Build 2", "Build 3", " Build", "Build\n", "", "\u{1F08}\u{0399}", "\u{1F80}",
            identifier, identifier.lowercased(),
        ]
    }()

    /// Every list of up to four names from ``alphabet``, repeats included.
    private static var everyList: [[String]] {
        var lists: [[String]] = [[]]
        var longest: [[String]] = [[]]
        for _ in 1...4 {
            longest = longest.flatMap { list in alphabet.map { list + [$0] } }
            lists += longest
        }
        return lists
    }

    @Test(
        "Every list of siblings is given names that are well formed and that Cocoa's matcher relates no two of, and a well-formed name no earlier sibling's is kept"
    )
    func everyListIsGivenDistinctWellFormedNames() {
        for stored in Self.everyList {
            let assigned = NameRule.assignment(of: stored, fallback: "Untitled")

            #expect(assigned.count == stored.count, "\(stored)")
            for (index, name) in assigned.enumerated() {
                #expect(Self.isWellFormed(name), "\(stored) gave \(assigned)")
                for later in assigned[(index + 1)...] {
                    #expect(!Self.cocoaRelates(name, later), "\(stored) gave \(assigned)")
                }
                let own = stored[index]
                if Self.isWellFormed(own), !stored[..<index].contains(where: { Self.cocoaRelates($0, own) }) {
                    #expect(name == own, "\(stored) gave \(assigned)")
                }
            }
        }
    }

    @Test(
        "Two names Cocoa's matcher relates, either way round, are one name, for every scalar's case and normalization variants"
    )
    func everyPairCocoaRelatesIsOneName() {
        for value in 0...0x1FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let name = String(Character(scalar))
            let variants: Set = [
                name.uppercased(), name.lowercased(), name.capitalized,
                name.decomposedStringWithCanonicalMapping, name.precomposedStringWithCanonicalMapping,
            ]
            for variant in variants where variant != name && Self.cocoaRelates(name, variant) {
                #expect(NameRule.text(variant, names: name), "U+\(String(value, radix: 16, uppercase: true))")
            }
        }
    }
}
