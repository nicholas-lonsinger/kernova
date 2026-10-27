import Foundation

/// What typed text names among a VM's snapshots — the one rule every surface
/// that lets a caller type a snapshot resolves it by.
public enum SnapshotSelection<Candidate> {
    case found(Candidate)
    case notFound
    /// More than one snapshot carries the name; the candidates say which.
    case ambiguous([Candidate])

    /// Text that parses as an identifier is matched against the identifiers
    /// first and falls back to the names, ignoring case, so a snapshot
    /// literally named after another's identifier is still reachable.
    public init(
        _ text: String, in candidates: [Candidate], id: (Candidate) -> UUID,
        name: (Candidate) -> String
    ) {
        if let identifier = UUID(uuidString: text),
            let match = candidates.first(where: { id($0) == identifier })
        {
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
}
