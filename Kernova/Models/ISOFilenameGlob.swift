import Foundation
import os

/// A catalog entry's ISO filename glob, compiled for matching the filenames a
/// checksum manifest lists.
///
/// `*` is the only metacharacter and absorbs a run of characters inside one
/// filename; every other character matches literally. The match is anchored at
/// both ends, which is what keeps a neighbouring variant out — Ubuntu's
/// `ubuntu-24.04.4-live-server-arm64+largemem.iso` cannot match a pattern
/// ending `-live-server-arm64.iso`.
struct ISOFilenameGlob: Sendable {
    private static let logger = Logger(subsystem: "app.kernova", category: "ISOFilenameGlob")

    private let regex: NSRegularExpression

    /// Compiles `pattern`, or `nil` when it does not translate to a regex.
    ///
    /// Every literal run is escaped, so a pattern that fails to compile is a
    /// mistake in this translation rather than in the catalog.
    init?(_ pattern: String) {
        let translated =
            pattern
            .components(separatedBy: "*")
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "([^/]*)")
        do {
            regex = try NSRegularExpression(pattern: "\\A\(translated)\\z")
        } catch {
            Self.logger.fault(
                "ISO pattern '\(pattern, privacy: .public)' did not translate to a regex")
            assertionFailure("ISO pattern did not translate to a regex: \(pattern)")
            return nil
        }
    }

    /// Whether `filename` matches, wholly, with nothing before or after.
    func matches(_ filename: String) -> Bool {
        wildcardText(in: filename) != nil
    }

    /// The text each `*` absorbed, in order, or `nil` when `filename` does not
    /// match.
    func wildcardText(in filename: String) -> [String]? {
        let whole = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let match = regex.firstMatch(in: filename, range: whole) else { return nil }
        return (1..<match.numberOfRanges).compactMap { group in
            Range(match.range(at: group), in: filename).map { String(filename[$0]) }
        }
    }

    /// The newest filename this glob matches, or `nil` when it matches none.
    ///
    /// Newest is decided by the numbers inside the text the pattern's `*`
    /// absorbed, never the whole filename: the literal part of a pattern
    /// carries numbers of its own that say nothing about the version — `arm64`
    /// in every one of them — and a point release adds a component rather than
    /// replacing one, so `26.04` and `26.04.1` differ only inside the wildcard.
    /// Filenames with equal versions order by name, so the answer is total.
    func newest(among filenames: some Sequence<String>) -> String? {
        filenames
            .compactMap { filename in
                wildcardText(in: filename).map {
                    (filename: filename, version: Self.versionKey($0.joined()))
                }
            }
            .max(by: { Self.isOlder($0, $1) })?
            .filename
    }

    /// The numbers embedded in `text`, in order, so `24.04.4` reads as
    /// `[24, 4, 4]` and 24.04.10 sorts above 24.04.9.
    ///
    /// A digit run too long to be an `Int` counts as zero, which is what keeps
    /// an absurd one from winning.
    static func versionKey(_ text: String) -> [Int] {
        var key: [Int] = []
        var digits = ""
        for character in text {
            if character.isASCII && character.isNumber {
                digits.append(character)
            } else if !digits.isEmpty {
                key.append(Int(digits) ?? 0)
                digits = ""
            }
        }
        if !digits.isEmpty { key.append(Int(digits) ?? 0) }
        return key
    }

    /// Whether `lhs` names an older image than `rhs`.
    ///
    /// A version stating fewer components is the shorter of the two on purpose:
    /// a missing component reads as zero, so `26.04` precedes `26.04.1`.
    private static func isOlder(
        _ lhs: (filename: String, version: [Int]), _ rhs: (filename: String, version: [Int])
    ) -> Bool {
        for index in 0..<max(lhs.version.count, rhs.version.count) {
            let left = index < lhs.version.count ? lhs.version[index] : 0
            let right = index < rhs.version.count ? rhs.version[index] : 0
            if left != right { return left < right }
        }
        return lhs.filename < rhs.filename
    }
}
