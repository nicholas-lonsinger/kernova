import Foundation

/// Collision-free name generation shared by every "pick the next free name"
/// site (clone names, default disk labels), so the de-duplication rule lives in
/// one place instead of being hand-rolled at each call.
enum UniqueName {
    /// Returns `prefix` when it's free, otherwise the first available
    /// `"<prefix> 2"`, `"<prefix> 3"`, and so on.
    ///
    /// Callers fold any infix into `prefix` (e.g. `"\(name) Copy"`), so the same
    /// loop backs both bare-numeric labels and `" Copy"`-style clone names. Matching is
    /// case-sensitive by default; pass `caseInsensitive: true` for filename reservation on a
    /// case-insensitive volume (the returned name keeps `prefix`'s original casing).
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
