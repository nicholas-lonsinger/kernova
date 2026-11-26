import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// What the name rule gives a list of siblings, judged by what Cocoa
/// Scripting's own matcher relates: NSString's `caseInsensitiveCompare(_:)`,
/// by which a script finds an element by name.
@Suite("Name rule", .caseScoped)
struct NameRuleTests {
    /// Whether Cocoa's matcher finds either name the same as the other.
    private static func cocoaRelates(_ lhs: String, _ rhs: String) -> Bool {
        (lhs as NSString).caseInsensitiveCompare(rhs) == .orderedSame
            || (rhs as NSString).caseInsensitiveCompare(lhs) == .orderedSame
    }

    /// Whether a sibling may go by `name` whatever else does: trimmed, holding
    /// more than whitespace, and spelling no identifier.
    private static func isWellFormed(_ name: String) -> Bool {
        !name.isEmpty && name.trimmingCharacters(in: .whitespacesAndNewlines) == name
            && UUID(uuidString: name) == nil
    }

    /// What names are drawn from: case variants, a name a later duplicate's
    /// first free name would land on, untrimmed and empty names, an
    /// identifier in either case, the Greek pair Cocoa's matcher relates one
    /// way only, and the pair it relates both ways though they fold to two
    /// keys.
    private static let alphabet: [String] = {
        let identifier = "6F1D7E2C-0000-4000-8000-0000000000AA"
        return [
            "Build", "build", "Build 2", "Build 3", " Build", "Build\n", "", identifier, identifier.lowercased(),
            "\u{1F08}\u{0399}", "\u{1F80}", "\u{1FCC}\u{0342}", "\u{1FC7}",
        ]
    }()

    /// Every list of up to `length` names from ``alphabet``, repeats included.
    private static func everyList(upTo length: Int) -> [[String]] {
        var lists: [[String]] = [[]]
        var longest: [[String]] = [[]]
        for _ in 0..<length {
            longest = longest.flatMap { list in alphabet.map { list + [$0] } }
            lists += longest
        }
        return lists
    }

    @Test(
        "Every list of siblings is given names that are well formed and that Cocoa's matcher relates no two of, and a well-formed name no earlier sibling's is related to is kept"
    )
    func everyListIsGivenDistinctWellFormedNames() {
        for stored in Self.everyList(upTo: 3) {
            let assigned = NameRule.assignment(of: stored) { _ in "Untitled" }

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
        "Beside every list of siblings, a name a caller chooses is taken, and a name Kernova counts up to is given, only where Cocoa's matcher relates it to none of them"
    )
    func everyChosenAndCountedNameIsFreeBesideItsSiblings() {
        for siblings in Self.everyList(upTo: 3) {
            for proposed in Self.alphabet {
                let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
                let free = Self.isWellFormed(trimmed) && !siblings.contains { Self.cocoaRelates($0, trimmed) }
                do {
                    let name = try NameRule.validated(proposed, among: siblings)
                    #expect(name == trimmed, "\(proposed) beside \(siblings)")
                    #expect(free, "\(proposed) beside \(siblings) was taken as \(name)")
                } catch {
                    #expect(!free, "\(proposed) beside \(siblings) was refused: \(error)")
                }
                guard Self.isWellFormed(proposed) else { continue }
                let counted = NameRule.firstAvailable(proposed, among: siblings)
                #expect(
                    !siblings.contains { Self.cocoaRelates($0, counted) },
                    "\(proposed) beside \(siblings) counted up to \(counted)")
            }
        }
    }
}
