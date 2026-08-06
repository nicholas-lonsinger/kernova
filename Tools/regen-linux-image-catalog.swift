#!/usr/bin/env swift
//
// Regenerate Kernova/Resources/LinuxImageCatalog.json — the Linux installer
// images offered by the creation wizard's distribution source.
//
// Everything written here is scraped from remote mirrors, and it reaches the
// shipped app through a reviewed diff — that review is the check on the input.
//
// Swift rather than the shell used by the other Tools scripts, for the same
// reasons as its macOS sibling: HTTP, three checksum-manifest grammars, and
// sorted JSON out.
//
// ## What this refreshes, and what it does not
//
// Which distributions are offered is a curated decision, so the entry list is
// edited by hand and this script never adds or removes one. What it refreshes
// is what the mirrors change on their own: the byte size behind each entry,
// and the version-pinned archive directory an oldstable entry points at.
//
// ## How an entry resolves
//
// Each entry names a directory, a checksum manifest inside it, and a glob for
// the ISO filename. The manifest is the index — no directory listing is
// parsed, and no filename is guessed. Three grammars appear across these
// mirrors, and all three are read here:
//
//   <hash>  <file>            GNU text mode (Debian, Kali)
//   <hash> *<file>            GNU binary mode (Ubuntu)
//   SHA256 (<file>) = <hash>  BSD, inside GPG clearsign armor (Fedora)
//
// Among the filenames the glob matches, the highest version wins — Ubuntu
// keeps several point releases of one series side by side.
//
// A run that cannot resolve every entry writes nothing and exits non-zero. A
// mirror reorganising its layout is the failure this catches, and a shipped
// catalog naming a file nobody serves is worse than a stale one.

import Foundation

// MARK: - Configuration

let repoRoot = URL(
    fileURLWithPath: CommandLine.arguments.first.map {
        URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent()
            .path
    } ?? FileManager.default.currentDirectoryPath)
let outputURL =
    repoRoot
    .appendingPathComponent("Kernova/Resources/LinuxImageCatalog.json")

// `repoRoot` is this script's own path minus two components, so a copy living
// anywhere but `Tools/` resolves somewhere else entirely and would write the
// catalog to a path nobody reads. Prove the root before trusting it.
guard
    FileManager.default.fileExists(
        atPath: repoRoot.appendingPathComponent("Kernova.xcodeproj").path(percentEncoded: false))
else {
    fail(
        "resolved the repository root as '\(repoRoot.path(percentEncoded: false))', which holds no "
            + "Kernova.xcodeproj — this script must live in Tools/")
}

// MARK: - Types

/// One catalog entry, in the shape `LinuxImageCatalogEntry` decodes.
struct CatalogEntry: Codable {
    var id: String
    var distribution: String
    var version: String
    var directoryURL: String
    var isoPattern: String
    var checksumManifest: String
    var approxSizeBytes: UInt64
}

struct Catalog: Codable {
    var generatedAt: String
    var images: [CatalogEntry]
}

/// One `(filename, hash)` pair read out of a checksum manifest.
struct ManifestRow {
    var filename: String
    var sha256: String
}

/// What one entry resolved to on this run.
struct Resolution {
    var entry: CatalogEntry
    var filename: String
    var notes: [String]
}

// MARK: - Helpers

func log(_ message: String) {
    FileHandle.standardError.write(Data(("• " + message + "\n").utf8))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("ERROR: " + message + "\n").utf8))
    exit(1)
}

let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
    return URLSession(configuration: configuration)
}()

/// Fetches a URL, following the geo-redirects Debian, Fedora and Kali answer
/// with (`URLSession` follows them by default; Ubuntu serves directly).
func get(_ url: URL) async -> Data? {
    guard let (data, response) = try? await session.data(from: url),
        let http = response as? HTTPURLResponse, http.statusCode == 200
    else { return nil }
    return data
}

/// The byte size a mirror reports for a file.
///
/// HEAD first; a mirror that declines it, or answers without a length, still
/// states the total in `Content-Range` when asked for a single byte.
func probeSize(_ url: URL) async -> UInt64? {
    var head = URLRequest(url: url)
    head.httpMethod = "HEAD"
    if let (_, response) = try? await session.data(for: head),
        let http = response as? HTTPURLResponse, http.statusCode == 200,
        let size = UInt64(exactly: http.expectedContentLength), size > 0
    {
        return size
    }

    var ranged = URLRequest(url: url)
    ranged.setValue("bytes=0-0", forHTTPHeaderField: "Range")
    guard let (_, response) = try? await session.data(for: ranged),
        let http = response as? HTTPURLResponse, http.statusCode == 206,
        let range = http.value(forHTTPHeaderField: "Content-Range"),
        let total = range.split(separator: "/").last, let size = UInt64(total), size > 0
    else { return nil }
    return size
}

/// Whether a string is a SHA-256 digest in hex.
func isSHA256(_ candidate: String) -> Bool {
    candidate.count == 64 && candidate.allSatisfy(\.isHexDigit)
}

/// Reads a `SHA256 (<file>) = <hash>` line.
func parseBSDLine(_ line: String) -> ManifestRow? {
    let prefix = "SHA256 ("
    guard line.hasPrefix(prefix) else { return nil }
    let rest = line.dropFirst(prefix.count)
    guard let separator = rest.range(of: ") = ") else { return nil }
    let filename = String(rest[rest.startIndex..<separator.lowerBound])
    let hash = String(rest[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
    guard !filename.isEmpty, isSHA256(hash) else { return nil }
    return ManifestRow(filename: filename, sha256: hash.lowercased())
}

/// Reads a `<hash>  <file>` line, in either text or binary (`*<file>`) mode.
func parseGNULine(_ line: String) -> ManifestRow? {
    let hash = line.prefix(while: \.isHexDigit)
    guard isSHA256(String(hash)) else { return nil }
    var rest = line.dropFirst(hash.count)
    guard rest.first == " " else { return nil }
    rest = rest.drop(while: { $0 == " " })
    if rest.first == "*" { rest = rest.dropFirst() }
    let filename = String(rest).trimmingCharacters(in: .whitespaces)
    guard !filename.isEmpty else { return nil }
    return ManifestRow(filename: filename, sha256: String(hash).lowercased())
}

/// Every `(filename, hash)` pair a manifest states, in any of the three
/// grammars, ignoring the clearsign armor Fedora wraps its manifest in.
func parseManifest(_ text: String) -> [ManifestRow] {
    var rows: [ManifestRow] = []
    for rawLine in text.split(whereSeparator: \.isNewline) {
        var line = String(rawLine)
        // Clearsigning escapes a line that began with a dash; the armor
        // delimiters and the header block are then the only dashes left.
        if line.hasPrefix("- ") { line = String(line.dropFirst(2)) }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-----"), !trimmed.hasPrefix("Hash:") else {
            continue
        }
        if let row = parseBSDLine(trimmed) ?? parseGNULine(trimmed) { rows.append(row) }
    }
    return rows
}

/// The text each `*` absorbed when the glob matches `name`, or `nil` when it
/// does not. `*` is the glob's only metacharacter.
func globCaptures(_ name: String, pattern: String) -> [String]? {
    let segments = pattern.components(separatedBy: "*")
    guard let first = segments.first, let last = segments.last else { return nil }
    guard segments.count > 1 else { return name == pattern ? [] : nil }
    guard name.hasPrefix(first) else { return nil }
    var captures: [String] = []
    var rest = Substring(name).dropFirst(first.count)
    for segment in segments.dropFirst().dropLast() {
        guard let found = rest.range(of: segment) else { return nil }
        captures.append(String(rest[..<found.lowerBound]))
        rest = rest[found.upperBound...]
    }
    guard rest.count >= last.count, rest.hasSuffix(last) else { return nil }
    captures.append(String(rest.dropLast(last.count)))
    return captures
}

/// Whether a filename matches a glob whose only metacharacter is `*`.
func matchesGlob(_ name: String, pattern: String) -> Bool {
    globCaptures(name, pattern: pattern) != nil
}

/// The numbers embedded in a filename, in order: `24.04.4` reads as
/// `[24, 4, 4]`, which is what makes 24.04.10 sort above 24.04.9.
func versionKey(_ name: String) -> [Int] {
    var key: [Int] = []
    var digits = ""
    for character in name {
        if character.isNumber {
            digits.append(character)
        } else if !digits.isEmpty {
            key.append(Int(digits) ?? 0)
            digits = ""
        }
    }
    if !digits.isEmpty { key.append(Int(digits) ?? 0) }
    return key
}

/// Orders two version-bearing strings (a directory name, or the text a glob's
/// wildcards absorbed), newest first.
func isNewerFilename(_ lhs: String, _ rhs: String) -> Bool {
    let left = versionKey(lhs)
    let right = versionKey(rhs)
    for index in 0..<max(left.count, right.count) {
        let leftPart = index < left.count ? left[index] : 0
        let rightPart = index < right.count ? right[index] : 0
        if leftPart != rightPart { return leftPart > rightPart }
    }
    return lhs > rhs
}

/// The version-pinned directory a URL points into, split into what precedes
/// it, the version itself, and what follows.
///
/// An oldstable release has no "current" URL to follow — it lives under a
/// directory named for one exact version, which stops being the newest when
/// the release gets a point update.
func pinnedVersionDirectory(in url: String) -> (base: String, version: String, tail: String)? {
    let segments = url.components(separatedBy: "/")
    guard
        let index = segments.firstIndex(where: { segment in
            let parts = segment.components(separatedBy: ".")
            return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && Int($0) != nil }
        })
    else { return nil }
    return (
        base: segments[..<index].joined(separator: "/") + "/",
        version: segments[index],
        tail: "/" + segments[(index + 1)...].joined(separator: "/")
    )
}

/// The newest version-pinned directory an index page lists for one release
/// series, or `nil` when the page names nothing newer than what is pinned.
func newerPinnedDirectory(for url: String) async -> String? {
    guard let pinned = pinnedVersionDirectory(in: url), let base = URL(string: pinned.base),
        let series = pinned.version.components(separatedBy: ".").first,
        let data = await get(base)
    else { return nil }

    let page = String(decoding: data, as: UTF8.self)
    var newest = pinned.version
    for reference in page.components(separatedBy: "href=\"").dropFirst() {
        guard let quote = reference.firstIndex(of: "\"") else { continue }
        let candidate = String(reference[reference.startIndex..<quote]).trimmingCharacters(
            in: CharacterSet(charactersIn: "/"))
        let parts = candidate.components(separatedBy: ".")
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && Int($0) != nil }),
            parts[0] == series, isNewerFilename(candidate, newest)
        else { continue }
        newest = candidate
    }
    guard newest != pinned.version else { return nil }
    return pinned.base + newest + pinned.tail
}

// MARK: - 1. Read the curated catalog

guard let published = try? Data(contentsOf: outputURL),
    let catalog = try? JSONDecoder().decode(Catalog.self, from: published)
else {
    fail(
        "could not read \(outputURL.path(percentEncoded: false)) — this script refreshes the "
            + "curated catalog rather than inventing one, so the file has to be there and parse")
}
log("Refreshing \(catalog.images.count) entry/entries against their mirrors…")

// MARK: - 2. Resolve every entry

var resolutions: [Resolution] = []
var failures: [(id: String, reason: String)] = []

for original in catalog.images {
    var entry = original
    var notes: [String] = []

    if let bumped = await newerPinnedDirectory(for: entry.directoryURL) {
        notes.append("directory bumped from \(entry.directoryURL)")
        entry.directoryURL = bumped
    }

    guard let directory = URL(string: entry.directoryURL), directory.scheme == "https" else {
        failures.append((entry.id, "'\(entry.directoryURL)' is not an HTTPS URL"))
        continue
    }
    let manifestURL = directory.appendingPathComponent(entry.checksumManifest)
    guard let manifestData = await get(manifestURL) else {
        failures.append(
            (
                entry.id,
                "no checksum manifest at \(manifestURL.absoluteString) — a respin renames the "
                    + "manifest, so check the directory and update checksumManifest"
            ))
        continue
    }

    let rows = parseManifest(String(decoding: manifestData, as: UTF8.self))
    guard !rows.isEmpty else {
        failures.append(
            (entry.id, "\(manifestURL.absoluteString) parsed as no (file, hash) pairs at all"))
        continue
    }
    // Newest is decided by the numbers inside the text the pattern's `*`
    // absorbed, never the whole filename — mirroring the app's
    // `ISOFilenameGlob.newest(among:)`: the literal part carries numbers that
    // say nothing about the version (`arm64` in every one of them), and a
    // point release adds a component inside the wildcard.
    let matches = rows.compactMap { row in
        globCaptures(row.filename, pattern: entry.isoPattern)
            .map { (filename: row.filename, captured: $0.joined()) }
    }
    guard
        let best = matches.sorted(by: {
            isNewerFilename($0.captured, $1.captured)
                || ($0.captured == $1.captured && $0.filename > $1.filename)
        }).first?.filename
    else {
        failures.append(
            (
                entry.id,
                "no filename in \(entry.checksumManifest) matched '\(entry.isoPattern)' "
                    + "(\(rows.count) pair(s) listed)"
            ))
        continue
    }

    let isoURL = directory.appendingPathComponent(best)
    guard let size = await probeSize(isoURL) else {
        failures.append((entry.id, "no size for \(isoURL.absoluteString)"))
        continue
    }

    // The version label is what the picker shows, and a mirror rolling forward
    // does not tell anyone. Reported rather than rewritten: only a person can
    // say whether "26.04 LTS" should have become "26.04.1".
    let label = entry.version.components(separatedBy: " ").first ?? entry.version
    if !best.contains(label) {
        notes.append("version label '\(entry.version)' does not appear in \(best)")
    }
    if entry.approxSizeBytes != size {
        notes.append("size \(entry.approxSizeBytes) → \(size)")
    }

    entry.approxSizeBytes = size
    resolutions.append(Resolution(entry: entry, filename: best, notes: notes))
}

// MARK: - 3. Refuse to publish a run that lost an entry

guard failures.isEmpty else {
    for (id, reason) in failures { log("  \(id) — \(reason)") }
    fail(
        "\(failures.count) entry/entries did not resolve — \(outputURL.lastPathComponent) is left "
            + "as it is")
}

// MARK: - 4. Emit

let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
let payload: [String: Any] = [
    "generatedAt": String(stamp),
    "images": resolutions.map { resolution -> [String: Any] in
        [
            "id": resolution.entry.id,
            "distribution": resolution.entry.distribution,
            "version": resolution.entry.version,
            "directoryURL": resolution.entry.directoryURL,
            "isoPattern": resolution.entry.isoPattern,
            "checksumManifest": resolution.entry.checksumManifest,
            "approxSizeBytes": resolution.entry.approxSizeBytes,
        ]
    },
]

var json = try JSONSerialization.data(
    withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
json.append(0x0A)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try json.write(to: outputURL, options: .atomic)

// MARK: - 5. Report

log("")
log("Wrote \(outputURL.path)")
for resolution in resolutions {
    log("  \(resolution.entry.id.padding(toLength: 24, withPad: " ", startingAt: 0))\(resolution.filename)")
    for note in resolution.notes { log("      \(note)") }
}
