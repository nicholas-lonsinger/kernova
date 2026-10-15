import Foundation

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
    /// and counted up before its last extension (`report 2.pdf`,
    /// `archive.tar 2.gz`) until nothing — a dangling symlink included —
    /// exists at that path.
    ///
    /// The name is not reserved: another writer can take it before the caller
    /// writes there.
    public static func uniqueDestination(in directory: URL, filename: String) -> URL {
        let sanitized = sanitizedComponent(filename) as NSString
        let ext = sanitized.pathExtension
        func withExtension(_ base: String) -> String { ext.isEmpty ? base : "\(base).\(ext)" }
        let base = firstAvailable(sanitized.deletingPathExtension) { base in
            let path = directory.appendingPathComponent(withExtension(base)).path
            // `attributesOfItem` reads the link itself; `fileExists` follows it
            // and calls a dangling link free, which a move onto it then refuses.
            return (try? FileManager.default.attributesOfItem(atPath: path)) != nil
        }
        return directory.appendingPathComponent(withExtension(base))
    }
}
