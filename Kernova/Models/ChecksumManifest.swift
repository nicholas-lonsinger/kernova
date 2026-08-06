import Foundation

/// The `(filename, SHA-256)` pairs a mirror publishes beside its images.
///
/// Three grammars appear across the mirrors the Linux catalog names, and a
/// manifest is read in all three:
///
///     <hash>  <file>            GNU text mode (Debian, Kali)
///     <hash> *<file>            GNU binary mode (Ubuntu)
///     SHA256 (<file>) = <hash>  BSD, inside GPG clearsign armor (Fedora)
///
/// A line in none of them is skipped rather than refused. Fedora's manifest is
/// a clearsigned document, so armor delimiters, the `Hash:` header, comments
/// and the base64 signature are all lines that are not checksums, and a mirror
/// that lists SHA-512 alongside SHA-256 lists both in the one file. Only the
/// SHA-256 pairs come back.
///
/// The signature is read past, never checked, and the manifest and the ISO are
/// two independent requests, each following its own redirect. So a digest from
/// here binds the ISO to whatever the manifest said — enough to catch a
/// corrupted or wrong file, not a hostile manifest naming a hostile ISO.
enum ChecksumManifest {
    /// One `(filename, digest)` pair a manifest states.
    struct Row: Sendable, Equatable {
        /// Filename as written in the manifest, relative to its directory.
        var filename: String
        /// The digest as 64 lowercase hex characters, whatever case it was
        /// written in.
        var sha256: String
    }

    /// Every SHA-256 pair `text` states, in the order the manifest lists them.
    ///
    /// Empty when the text holds no pair at all, which is what a mirror serving
    /// an error page or a directory listing in place of a manifest looks like.
    static func parse(_ text: String) -> [Row] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            // Clearsigning escapes a line that began with a dash, so a manifest
            // line inside the armor arrives with "- " in front of it.
            let line = rawLine.hasPrefix("- ") ? rawLine.dropFirst(2) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return parseBSDLine(trimmed) ?? parseGNULine(trimmed)
        }
    }

    /// Reads a `SHA256 (<file>) = <hash>` line.
    private static func parseBSDLine(_ line: String) -> Row? {
        let prefix = "SHA256 ("
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        guard let separator = rest.range(of: ") = ") else { return nil }
        let filename = String(rest[rest.startIndex..<separator.lowerBound])
        let hash = rest[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !filename.isEmpty, isSHA256(hash) else { return nil }
        return Row(filename: filename, sha256: hash.lowercased())
    }

    /// Reads a `<hash>  <file>` line, in text mode or binary mode (`*<file>`).
    private static func parseGNULine(_ line: String) -> Row? {
        let hash = line.prefix(while: isHexDigit)
        guard isSHA256(String(hash)) else { return nil }
        var rest = line.dropFirst(hash.count)
        guard rest.first == " " else { return nil }
        rest = rest.drop(while: { $0 == " " })
        if rest.first == "*" { rest = rest.dropFirst() }
        let filename = rest.trimmingCharacters(in: .whitespaces)
        guard !filename.isEmpty else { return nil }
        return Row(filename: filename, sha256: String(hash).lowercased())
    }

    /// Whether `candidate` is a SHA-256 digest written as 64 hex digits.
    ///
    /// A SHA-512 line, which several of these mirrors carry beside the SHA-256
    /// one, fails on the length. Also the shape a digest typed into the wizard
    /// is admitted on, so a manifest's digest and a user's are held to one rule.
    static func isSHA256(_ candidate: String) -> Bool {
        candidate.count == 64 && candidate.allSatisfy(isHexDigit)
    }

    /// Whether `character` is one of `0-9a-fA-F`.
    ///
    /// `Character.isHexDigit` also answers yes to the fullwidth forms, which no
    /// digest is written in.
    private static func isHexDigit(_ character: Character) -> Bool {
        character.isASCII && character.isHexDigit
    }
}
