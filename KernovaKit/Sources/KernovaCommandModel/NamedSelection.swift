import Foundation

/// What typed text names among a list of items — the one rule every surface
/// that lets a caller type an item by its name resolves it by: a snapshot, a
/// shared directory, a USB accessory, a remembered USB accessory.
public enum NamedSelection<Candidate> {
    case found(Candidate)
    case notFound
    /// More than one item carries the name; the candidates say which.
    case ambiguous([Candidate])

    /// Text that is an item's identifier — the one `identifies` answers true
    /// for — names that item; any other text names the one item whose name it
    /// is, ignoring case. So an item literally named after another's
    /// identifier is still reachable by name, and the identifier always
    /// reaches its own.
    public init(
        _ text: String, in candidates: [Candidate], identifiedBy identifies: (Candidate) -> Bool,
        name: (Candidate) -> String
    ) {
        if let match = candidates.first(where: identifies) {
            self = .found(match)
            return
        }
        let matching = candidates.filter { name($0).caseInsensitiveCompare(text) == .orderedSame }
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
