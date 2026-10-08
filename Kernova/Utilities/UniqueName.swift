import Foundation

/// Collision-free name generation shared by every "pick the next free name"
/// site: clone names, default disk labels, filenames, and the names of smart
/// groups, folders and tags.
enum UniqueName {
    /// Returns `prefix` when it's free, otherwise the first available
    /// `"<prefix> 2"`, `"<prefix> 3"`, and so on.
    ///
    /// Callers fold any infix into `prefix` (e.g. `"\(name) Copy"`). Matching is
    /// case-sensitive unless `caseInsensitive` is set; set, it matches by
    /// `caseInsensitiveCompare` — the comparison an organization name's
    /// uniqueness is refused by, so a change to it changes which names that
    /// accepts. The returned name keeps `prefix`'s casing.
    static func firstAvailable(prefix: String, existing: [String], caseInsensitive: Bool = false) -> String {
        func isTaken(_ candidate: String) -> Bool {
            if caseInsensitive {
                return existing.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
            }
            return existing.contains(candidate)
        }
        guard isTaken(prefix) else { return prefix }
        var counter = 2
        while isTaken("\(prefix) \(counter)") {
            counter += 1
        }
        return "\(prefix) \(counter)"
    }
}
