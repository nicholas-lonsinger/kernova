import Foundation

/// The guard a filename named by a remote source passes before it is appended
/// to a directory.
///
/// `URL.lastPathComponent` percent-decodes, so a URL ending in
/// `a%2F..%2F..%2Fevil.ipsw` hands back `a/../../evil.ipsw` — a value that walks
/// out of whatever directory it is appended to. A checksum manifest states the
/// same kind of value without the encoding: the name is whatever the mirror
/// wrote on that line.
enum SafeFilename {
    /// `candidate` when it is one visible path component named
    /// `.<fileExtension>`, `nil` when the caller must generate a name instead.
    ///
    /// Anything empty, hidden (`.` and `..` included), carrying a separator, or
    /// carrying another extension is refused. The extension is matched
    /// case-insensitively and `candidate` comes back exactly as it went in.
    static func sanitized(_ candidate: String, requiring fileExtension: String) -> String? {
        guard candidate.lowercased().hasSuffix(".\(fileExtension.lowercased())"),
            isSingleComponent(candidate)
        else { return nil }
        return candidate
    }

    /// Whether `candidate` is one visible path component.
    static func isSingleComponent(_ candidate: String) -> Bool {
        // `.` and `..` fall out of the leading-dot refusal.
        guard !candidate.isEmpty, !candidate.hasPrefix(".") else { return false }
        let decoded = candidate.removingPercentEncoding ?? candidate
        return !candidate.contains(where: isSeparator)
            && !decoded.contains(where: isSeparator)
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character == "/" || character == "\0"
    }
}
