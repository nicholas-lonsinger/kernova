import Foundation

/// Names an arriving file inside a folder the user browses, using Finder's own
/// "Keep Both" convention: `report.pdf` → `report 2.pdf` → `report 3.pdf`, and
/// `Photos` → `Photos 2` for an extensionless name or a folder.
///
/// Distinct from `ClipboardFileStaging`'s internal ` (n)` suffixing, which names
/// files inside an invisible staging root that no one reads: a dropped file lands
/// in the guest's Downloads folder and the drop ends in a Finder window, so its
/// name has to be the one Finder itself would have produced.
public enum FinderStyleUniquing {
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

    /// A URL under `directory` for `filename`, suffixed ` 2`, ` 3`, … before the
    /// extension until nothing exists at that path.
    ///
    /// The existence probe is inherently racy against another writer in the same
    /// directory; the caller's move is the operation that has to fail safe.
    /// `fileExists` follows a symlink's target, so a dangling symlink is treated
    /// as free and the move replaces it — which is what the user asked for.
    public static func uniqueDestination(
        in directory: URL, filename: String, fileManager: FileManager = .default
    ) -> URL {
        let sanitized = sanitizedComponent(filename)
        let candidate = directory.appendingPathComponent(sanitized)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let name = sanitized as NSString
        let base = name.deletingPathExtension
        let ext = name.pathExtension
        var counter = 2
        while true {
            let suffixed = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            let url = directory.appendingPathComponent(suffixed)
            if !fileManager.fileExists(atPath: url.path) { return url }
            counter += 1
        }
    }
}
