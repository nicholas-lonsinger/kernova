import Foundation

/// The "first free name" search: a name is used as-is when it is free,
/// otherwise the first free one of `<name> 2`, `<name> 3`, ….
public enum NameUniquing {
    /// `name` when `isTaken(name)` is false, otherwise the first of
    /// `"<name> 2"`, `"<name> 3"`, … for which it is false — counted after the
    /// whole name, dots included.
    public static func firstAvailable(_ name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        var counter = 2
        while isTaken("\(name) \(counter)") {
            counter += 1
        }
        return "\(name) \(counter)"
    }
}
