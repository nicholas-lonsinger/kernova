import Foundation
import KernovaFileTree

/// The one "first free name" search: a name is used as-is when it is free,
/// otherwise the first free one of `<name> 2`, `<name> 3`, … — Finder's
/// "Keep Both" spelling.
public enum NameUniquing {
    /// Reduces a peer-supplied filename to a single safe path component, so a
    /// crafted name (`"../escape"`, `"a/b"`) cannot write outside the destination
    /// directory.
    ///
    /// An empty, `.`, or `..` result falls back to `fallback`.
    public static func sanitizedComponent(
        _ filename: String, fallback: String = "clipboard-file"
    ) -> String {
        let base = (filename as NSString).lastPathComponent
        let cleaned = base.replacingOccurrences(of: "/", with: "_")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? fallback : cleaned
    }

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

    /// A URL under `directory` for `filename`, sanitized to one path component
    /// and counted up as `KeepBothName` spells it (`report 2.pdf`,
    /// `archive.tar 2.gz`) until nothing — a dangling symlink included —
    /// exists at that path.
    ///
    /// The name is not reserved: another writer can take it before the caller
    /// writes there.
    public static func uniqueDestination(in directory: URL, filename: String) -> URL {
        let sanitized = Array(sanitizedComponent(filename).utf8)
        var number = 1
        while true {
            let url = directory.appendingPathComponent(
                String(decoding: KeepBothName.candidate(sanitized, number), as: UTF8.self))
            // `attributesOfItem` reads the link itself; `fileExists` follows it
            // and calls a dangling link free, which a move onto it then refuses.
            if (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil { return url }
            number += 1
        }
    }
}
