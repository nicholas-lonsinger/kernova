import Foundation
import KernovaKit

/// Collision-free name generation for the names the app picks against a list
/// it holds: clone names, default disk labels, bundle names, and the names of
/// smart groups, folders and tags.
enum UniqueName {
    /// Returns `prefix` when it's free, otherwise the first available
    /// `"<prefix> 2"`, `"<prefix> 3"`, and so on — counted after the whole
    /// prefix, dots included.
    ///
    /// Callers fold any infix into `prefix` (e.g. `"\(name) Copy"`). Matching is
    /// case-sensitive unless `caseInsensitive` is set; set, it matches by
    /// `caseInsensitiveCompare` — the comparison an organization name's
    /// uniqueness is refused by, so a change to it changes which names that
    /// accepts. The returned name keeps `prefix`'s casing.
    static func firstAvailable(prefix: String, existing: [String], caseInsensitive: Bool = false) -> String {
        NameUniquing.firstAvailable(prefix) { candidate in
            if caseInsensitive {
                return existing.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
            }
            return existing.contains(candidate)
        }
    }
}
