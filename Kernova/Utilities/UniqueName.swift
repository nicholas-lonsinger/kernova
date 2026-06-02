import Foundation

/// Collision-free name generation shared by every "pick the next free name"
/// site (clone names, default disk labels), so the de-duplication rule lives in
/// one place instead of being hand-rolled at each call.
enum UniqueName {
    /// Returns `prefix` when it's free, otherwise the first available
    /// `"<prefix> 2"`, `"<prefix> 3"`, … Case-sensitive exact match.
    ///
    /// Callers fold any infix into `prefix` (e.g. `"\(name) Copy"`), so the same
    /// loop backs both bare-numeric labels and `" Copy"`-style clone names.
    static func firstAvailable(prefix: String, existing: [String]) -> String {
        guard existing.contains(prefix) else { return prefix }
        var counter = 2
        while existing.contains("\(prefix) \(counter)") {
            counter += 1
        }
        return "\(prefix) \(counter)"
    }
}
