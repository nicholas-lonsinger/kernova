import Foundation
import KernovaKit

/// What typed text names among a list of items whose names are not held
/// unique — a snapshot, a shared directory, a USB accessory, a remembered USB
/// accessory.
public enum NamedSelection<Candidate> {
    case found(Candidate)
    case notFound
    /// More than one item carries the name; the candidates say which.
    case ambiguous([Candidate])

    /// Text that is an item's identifier — the first `identifies` answers true
    /// for — names that item, whatever any item is called; any other text
    /// names the one item whose name it is (``NameRule/text(_:names:)``). An
    /// identifier always reaches its own item, so an item whose name is
    /// another's identifier is reached only by its own identifier.
    public init(
        _ text: String, in candidates: [Candidate], identifiedBy identifies: (Candidate) -> Bool,
        name: (Candidate) -> String
    ) {
        if let match = candidates.first(where: identifies) {
            self = .found(match)
            return
        }
        let matching = candidates.filter { NameRule.text(text, names: name($0)) }
        switch matching.count {
        case 0: self = .notFound
        case 1: self = .found(matching[0])
        default: self = .ambiguous(matching)
        }
    }

    /// The rule for items identified by a UUID: text that parses as one names
    /// the item it identifies.
    public init(
        _ text: String, in candidates: [Candidate], id: (Candidate) -> UUID, name: (Candidate) -> String
    ) {
        let identifier = UUID(uuidString: text)
        self.init(text, in: candidates, identifiedBy: { id($0) == identifier }, name: name)
    }
}
