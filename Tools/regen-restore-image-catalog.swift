#!/usr/bin/env swift
//
// Regenerate Kernova/Resources/RestoreImageCatalog.json — the macOS restore
// images offered by the creation wizard's "Choose a Version…" source.
//
// Run before cutting a release, and any time Apple ships a macOS build.
//
// Swift rather than the shell used by the other Tools scripts: this parses a
// property list, performs conditional HTTP, and emits sorted JSON, none of
// which sed/awk do well. `swift` is already required to build the project.
//
// ## Where the data comes from
//
// Apple's asset feed publishes exactly one restore image per device — the
// current one. Every *past* build was that entry in its turn, so the history is
// recovered by replaying archived copies of the same Apple feed.
//
//   apple-live      the feed as it stands right now
//   apple-archived  the same Apple feed, read from a dated archive snapshot
//   apple-indexed   an Apple image URL recovered from an archive's crawl index,
//                   covering releases that were never current when a snapshot
//                   happened to be taken
//
// All three are Apple's own URLs. No third-party catalog is consulted, so
// nothing here carries an attribution obligation. No build ships on an
// archive's say-so either: every candidate URL is re-verified against Apple's
// live CDN below, and only what Apple serves today is written out. The archive
// supplies the URL to ask about; Apple supplies the answer, including the size
// and Last-Modified date recorded for each image.

import Foundation

// MARK: - Configuration

/// Resolves a URL that is a compile-time constant.
///
/// A nil here means the literal below was mistyped, which is a bug to surface
/// at once rather than carry into a generated catalog.
func requireURL(_ string: String) -> URL {
    guard let url = URL(string: string) else { fail("malformed URL literal: \(string)") }
    return url
}

let device = "VirtualMac2,1"
let feedURL = requireURL(
    "https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml")
let cdxURL = requireURL(
    "http://web.archive.org/cdx/search/cdx?url=mesu.apple.com/assets/macos/"
        + "com_apple_macOSIPSW/com_apple_macOSIPSW.xml&output=json&collapse=digest&fl=timestamp")

/// Only these hosts may appear in a shipped URL.
///
/// A restore image comes from Apple or it does not ship.
let allowedHosts: Set<String> = ["updates.cdn-apple.com", "mesu.apple.com"]

/// A seed build number, such as `26A5388g`.
///
/// Major, train letter, a 5-prefixed four-digit counter, and a lowercase
/// revision. Release builds carry a shorter counter (`25G72`) or one that does
/// not start with 5 (`24B2083`, the M4 spin of 15.1).
///
/// The URL is no help here. Apple served the *shipping* build of macOS 13.3
/// (`22E252`) out of a `2023WinterSeed/` directory, so the path segment marks
/// which release train produced the image, not whether it is a beta.
let seedBuild: Regex<AnyRegexOutput> = {
    guard let pattern = try? Regex(#"^\d+[A-Z]5\d{3}[a-z]$"#) else {
        fail("seed-build pattern failed to compile")
    }
    return pattern
}()

func isSeed(_ build: String) -> Bool {
    build.wholeMatch(of: seedBuild) != nil
}

let repoRoot = URL(
    fileURLWithPath: CommandLine.arguments.first.map {
        URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent()
            .path
    } ?? FileManager.default.currentDirectoryPath)
let outputURL =
    repoRoot
    .appendingPathComponent("Kernova/Resources/RestoreImageCatalog.json")

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

/// Snapshot cache.
///
/// Archived copies never change, so a cached one is refetched only when absent,
/// which keeps repeat runs off the archive entirely.
let cacheDir = URL(
    fileURLWithPath: ProcessInfo.processInfo.environment["KERNOVA_CATALOG_CACHE"]
        ?? NSTemporaryDirectory() + "kernova-restore-image-catalog")

// MARK: - Types

struct Candidate {
    var version: String
    var build: String
    var url: URL
    var source: String
    var snapshot: String?
}

struct Image {
    var version: String
    var build: String
    var url: URL
    var sizeBytes: Int64
    var lastModified: String?
    var source: String
    var snapshot: String?
}

// MARK: - Helpers

func log(_ message: String) {
    FileHandle.standardError.write(Data(("• " + message + "\n").utf8))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("ERROR: " + message + "\n").utf8))
    exit(1)
}

/// Decodes a feed body, transparently gunzipping when the archive replayed the
/// original gzip-encoded response.
func decodeFeed(_ data: Data) -> [String: Any]? {
    if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
        let dict = plist as? [String: Any]
    {
        return dict
    }
    guard data.starts(with: [0x1f, 0x8b]) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
    process.arguments = ["-c"]
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    // Write on a background queue: gunzip's output pipe fills and blocks the
    // child while we are still writing, which deadlocks a same-thread write.
    DispatchQueue.global().async {
        input.fileHandleForWriting.write(data)
        try? input.fileHandleForWriting.close()
    }
    let inflated = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard let plist = try? PropertyListSerialization.propertyList(from: inflated, format: nil)
    else { return nil }
    return plist as? [String: Any]
}

/// Pulls this device's restore entries out of a decoded feed.
func candidates(in feed: [String: Any], source: String, snapshot: String?) -> [Candidate] {
    guard
        let byVersion = feed["MobileDeviceSoftwareVersionsByVersion"] as? [String: Any],
        let first = byVersion["1"] as? [String: Any],
        let devices = first["MobileDeviceSoftwareVersions"] as? [String: Any],
        let builds = devices[device] as? [String: Any]
    else { return [] }

    return builds.compactMap { build, payload in
        guard
            let entry = payload as? [String: Any],
            let restore = entry["Restore"] as? [String: Any],
            let version = restore["ProductVersion"] as? String,
            let raw = restore["FirmwareURL"] as? String,
            let url = URL(string: raw)
        else { return nil }
        return Candidate(
            version: version, build: build, url: url, source: source, snapshot: snapshot)
    }
}

/// Orders candidates newest first.
///
/// Numeric per component so 26.10 sorts above 26.9.
func isDescending(_ a: Candidate, _ b: Candidate) -> Bool {
    let lhs = a.version.split(separator: ".").map { Int($0) ?? 0 }
    let rhs = b.version.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(lhs.count, rhs.count) {
        let l = i < lhs.count ? lhs[i] : 0
        let r = i < rhs.count ? rhs[i] : 0
        if l != r { return l > r }
    }
    return a.build > b.build
}

let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
    return URLSession(configuration: configuration)
}()

func get(_ url: URL) async -> Data? {
    guard let (data, response) = try? await session.data(from: url),
        let http = response as? HTTPURLResponse, http.statusCode == 200
    else { return nil }
    return data
}

/// Fetches a byte range.
///
/// Apple's CDN honours `Range` on restore images, which is what makes the
/// hardware-model check below cost kilobytes instead of gigabytes.
func getRange(_ url: URL, from offset: Int64, count: Int64) async -> [UInt8]? {
    guard count > 0 else { return nil }
    var request = URLRequest(url: url)
    request.setValue("bytes=\(offset)-\(offset + count - 1)", forHTTPHeaderField: "Range")
    guard let (data, response) = try? await session.data(for: request),
        let http = response as? HTTPURLResponse, http.statusCode == 206 || http.statusCode == 200
    else { return nil }
    return [UInt8](data)
}

func readLE<T: FixedWidthInteger>(_ bytes: [UInt8], _ offset: Int, _ type: T.Type) -> T? {
    let width = MemoryLayout<T>.size
    guard offset >= 0, offset + width <= bytes.count else { return nil }
    var value: T = 0
    for i in (0..<width).reversed() { value = (value << 8) | T(bytes[offset + i]) }
    return value
}

func lastIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
    guard haystack.count >= needle.count else { return nil }
    for start in stride(from: haystack.count - needle.count, through: 0, by: -1)
    where Array(haystack[start..<start + needle.count]) == needle {
        return start
    }
    return nil
}

/// Whether a restore image contains the virtual-machine hardware model.
///
/// An IPSW is a zip. Its central directory lists `kernelcache.release.vma2` and
/// `apticket.vma2macosap.im4m` exactly when the image can install into a VM, so
/// reading the directory alone settles it — three ranged requests and roughly
/// 150 KB rather than the whole multi-gigabyte file.
///
/// Checked against the framework on both outcomes: macOS 11.6 (`20G165`) has no
/// `vma2` and `VZMacOSRestoreImage` reports `mostFeaturefulSupportedConfiguration`
/// nil for it, while macOS 12.0.1 (`21A559`) has `vma2` and the framework returns
/// a supported configuration. `nil` here means the structure could not be read,
/// which is not the same as a "no".
func supportsVirtualMachine(_ url: URL, totalBytes: Int64) async -> Bool? {
    let window: Int64 = 131_072
    let tailStart = max(0, totalBytes - window)
    guard let tail = await getRange(url, from: tailStart, count: totalBytes - tailStart),
        let eocd = lastIndex(of: [0x50, 0x4B, 0x05, 0x06], in: tail),
        var directorySize = readLE(tail, eocd + 12, UInt32.self).map(Int64.init),
        var directoryOffset = readLE(tail, eocd + 16, UInt32.self).map(Int64.init)
    else { return nil }

    // Every one of these images exceeds 4 GB, so the real offsets live in the
    // zip64 record the locator points at; the 32-bit fields above are sentinels.
    if let locator = lastIndex(of: [0x50, 0x4B, 0x06, 0x07], in: tail),
        let zip64Offset = readLE(tail, locator + 8, UInt64.self),
        let header = await getRange(url, from: Int64(zip64Offset), count: 64),
        Array(header.prefix(4)) == [0x50, 0x4B, 0x06, 0x06],
        let size = readLE(header, 40, UInt64.self),
        let offset = readLE(header, 48, UInt64.self)
    {
        directorySize = Int64(size)
        directoryOffset = Int64(offset)
    }

    guard directorySize > 0, directoryOffset >= 0,
        let directory = await getRange(url, from: directoryOffset, count: directorySize)
    else { return nil }
    return lastIndex(of: [UInt8]("vma2".utf8), in: directory) != nil
}

// MARK: - 1. Apple, live

log("Reading Apple's asset feed…")
guard let liveData = await get(feedURL), let liveFeed = decodeFeed(liveData) else {
    fail("could not read \(feedURL.absoluteString)")
}
var pool: [String: Candidate] = [:]
for candidate in candidates(in: liveFeed, source: "apple-live", snapshot: nil) {
    pool[candidate.build] = candidate
}
log("  \(pool.count) build(s) currently published")

// MARK: - 2. Apple, archived

log("Listing archived copies of the same feed…")
var timestamps: [String] = []
if let cdxData = await get(cdxURL),
    let rows = try? JSONSerialization.jsonObject(with: cdxData) as? [[String]]
{
    timestamps = rows.dropFirst().compactMap(\.first)
}
log("  \(timestamps.count) distinct snapshot(s)")

try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

var replayed = 0
for stamp in timestamps {
    let cached = cacheDir.appendingPathComponent("\(stamp).feed")
    var body = try? Data(contentsOf: cached)
    if body == nil {
        let replay = requireURL(
            "https://web.archive.org/web/\(stamp)id_/\(feedURL.absoluteString)")
        body = await get(replay)
        if let body { try? body.write(to: cached) }
        // Deliberately unhurried: the archive is a donated public service and
        // this loop is the only thing in Kernova that touches it.
        try? await Task.sleep(nanoseconds: 400_000_000)
    }
    guard let body, let feed = decodeFeed(body) else { continue }
    replayed += 1
    for candidate in candidates(in: feed, source: "apple-archived", snapshot: stamp) {
        // Live wins; among archives the earliest snapshot to carry a build is
        // the one credited, so the recorded provenance is the first sighting.
        if let existing = pool[candidate.build] {
            if existing.source == "apple-live" { continue }
            if let seen = existing.snapshot, seen <= stamp { continue }
        }
        pool[candidate.build] = candidate
    }
}
log("  \(replayed) snapshot(s) read, \(pool.count) distinct build(s) total")

// MARK: - 3. Apple URLs recovered from the archive's crawl index
//
// A release that shipped and was superseded between two snapshots leaves no
// trace in the feed history, but its image URL is still indexed if a crawler
// ever encountered it. The index reaches back years and lags the present by
// weeks, so what it adds is history.

log("Reading the archive's index of Apple image URLs…")
let indexURL = requireURL(
    "http://web.archive.org/cdx/search/cdx?url=updates.cdn-apple.com*"
        + "&filter=original:.*UniversalMac.*Restore%5C.ipsw"
        + "&output=json&collapse=urlkey&fl=original")
var indexed = 0
if let data = await get(indexURL),
    let rows = try? JSONSerialization.jsonObject(with: data) as? [[String]]
{
    for row in rows.dropFirst() {
        guard let raw = row.first, let url = URL(string: raw),
            url.host == "updates.cdn-apple.com"
        else { continue }
        let name = url.lastPathComponent
        let parts = name.replacingOccurrences(of: "UniversalMac_", with: "")
            .replacingOccurrences(of: "_Restore.ipsw", with: "")
            .split(separator: "_")
        guard parts.count == 2 else { continue }
        let version = String(parts[0]), build = String(parts[1])
        // No version filter here — whether an image can run as a guest is
        // settled by reading its hardware models during verification, not by
        // guessing from the version number.
        guard !isSeed(build) else { continue }
        guard pool[build] == nil else { continue }
        pool[build] = Candidate(
            version: version, build: build, url: url, source: "apple-indexed", snapshot: nil)
        indexed += 1
    }
}
log("  \(indexed) additional build(s) from the index, \(pool.count) distinct total")

// MARK: - 4. Verify every candidate against Apple

log("Verifying each image against Apple's CDN…")
var images: [Image] = []
var rejected: [(String, String)] = []

for candidate in pool.values.sorted(by: isDescending) {
    guard candidate.url.scheme == "https",
        let host = candidate.url.host, allowedHosts.contains(host)
    else {
        rejected.append(("\(candidate.version) (\(candidate.build))", "not an Apple HTTPS URL"))
        continue
    }
    var request = URLRequest(url: candidate.url)
    request.httpMethod = "HEAD"
    guard let (_, response) = try? await session.data(for: request),
        let http = response as? HTTPURLResponse
    else {
        rejected.append(("\(candidate.version) (\(candidate.build))", "no response"))
        continue
    }
    guard http.statusCode == 200 else {
        rejected.append(("\(candidate.version) (\(candidate.build))", "HTTP \(http.statusCode)"))
        continue
    }
    let size = http.expectedContentLength
    guard size > 0 else {
        rejected.append(("\(candidate.version) (\(candidate.build))", "no content length"))
        continue
    }
    switch await supportsVirtualMachine(candidate.url, totalBytes: size) {
    case .some(true):
        break
    case .some(false):
        rejected.append(("\(candidate.version) (\(candidate.build))", "no virtual-machine hardware model"))
        continue
    case nil:
        rejected.append(("\(candidate.version) (\(candidate.build))", "could not read hardware models"))
        continue
    }
    images.append(
        Image(
            version: candidate.version, build: candidate.build, url: candidate.url,
            sizeBytes: size,
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            source: candidate.source, snapshot: candidate.snapshot))
}

// MARK: - 4. Emit

let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
var payload: [String: Any] = [
    "device": device,
    "generatedAt": String(stamp),
    "images": images.map { image -> [String: Any] in
        var row: [String: Any] = [
            "version": image.version,
            "build": image.build,
            "url": image.url.absoluteString,
            "sizeBytes": image.sizeBytes,
            "source": image.source,
            "verifiedAt": String(stamp),
        ]
        if let lastModified = image.lastModified { row["lastModified"] = lastModified }
        if let snapshot = image.snapshot { row["snapshot"] = snapshot }
        return row
    },
]
payload["imageCount"] = images.count

let json = try JSONSerialization.data(
    withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try json.write(to: outputURL, options: .atomic)

// MARK: - 5. Report

log("")
log("Wrote \(outputURL.path)")
for source in ["apple-live", "apple-archived", "apple-indexed"] {
    let count = images.filter { $0.source == source }.count
    log("  \(source.padding(toLength: 22, withPad: " ", startingAt: 0))\(count)")
}
log("  ──────────────────────────")
log("  verified against Apple \(images.count)")
if !rejected.isEmpty {
    log("  not shipped            \(rejected.count)")
    for (version, reason) in rejected { log("      \(version) — \(reason)") }
}
