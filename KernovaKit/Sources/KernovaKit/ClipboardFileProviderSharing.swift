import Foundation

// Shared item-identity + offer-manifest machinery for the guest File Provider
// transport (issue #376).
//
// The File Provider extension owns the enumerator, but the agent (a separate
// process) knows the current clipboard offer. The framework has no "push items"
// API — the system learns items *only* by calling the extension's enumerator —
// so the two processes agree on the current item set through a small manifest
// the agent writes into the shared app-group container and the extension reads.
// After writing it the agent calls `signalEnumerator` to prompt re-enumeration.
//
// All types here are value types or stateless file helpers: synchronization
// across the two processes is the atomic manifest write, not shared memory, so
// none of this needs lock-based `@unchecked Sendable`.

/// Encodes and decodes a file representation's `(generation, repIndex)` as a
/// `NSFileProviderItemIdentifier` string.
///
/// The string is carried as a plain `String` here (not `NSFileProviderItemIdentifier`)
/// so the encoding is unit-testable without importing `FileProvider`; the
/// extension wraps it. The `clipfile` prefix distinguishes a per-rep file item
/// from the framework's reserved container identifiers (root / working-set /
/// trash). Avoids `/` and `:`, which the framework reserves.
enum ClipboardFileProviderItemIdentifier {
    private static let prefix = "clipfile"
    private static let separator: Character = "."

    /// Encodes `(generation, repIndex)` into an item identifier string.
    static func make(generation: UInt64, repIndex: Int) -> String {
        "\(prefix)\(separator)\(generation)\(separator)\(repIndex)"
    }

    /// Decodes an identifier string back to `(generation, repIndex)`, or `nil`
    /// when it isn't one this provider minted.
    static func decode(_ identifier: String) -> (generation: UInt64, repIndex: Int)? {
        let parts = identifier.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == prefix,
            let generation = UInt64(parts[1]),
            let repIndex = Int(parts[2]), repIndex >= 0
        else { return nil }
        return (generation, repIndex)
    }
}

/// The current offer's file items, written by the agent and read by the
/// extension's enumerator.
///
/// One entry per File-Provider-served file rep.
public struct ClipboardFileProviderManifest: Codable, Sendable, Equatable {
    /// One enumerable file item: its `(generation, repIndex)` identity plus the
    /// metadata the enumerator needs to build a dataless `NSFileProviderItem`.
    public struct Item: Codable, Sendable, Equatable {
        /// Offer generation this item belongs to.
        public var generation: UInt64
        /// Index of the file representation within the offer.
        public var repIndex: Int
        /// Suggested filename — the placeholder's name under the domain root.
        public var filename: String
        /// Total byte count, surfaced as the item's `documentSize`.
        public var byteCount: UInt64
        /// Content UTI, mapped to the item's `contentType`.
        public var uti: String

        /// Creates a manifest item from a file rep's identity and metadata.
        public init(
            generation: UInt64, repIndex: Int, filename: String, byteCount: UInt64, uti: String
        ) {
            self.generation = generation
            self.repIndex = repIndex
            self.filename = filename
            self.byteCount = byteCount
            self.uti = uti
        }

        /// The File Provider item identifier string for this entry.
        public var itemIdentifier: String {
            ClipboardFileProviderItemIdentifier.make(generation: generation, repIndex: repIndex)
        }
    }

    /// The offer generation this manifest describes; `0` means no current offer.
    public var generation: UInt64
    /// One entry per File-Provider-served file rep in the current offer.
    public var items: [Item]

    /// Creates a manifest for an offer generation and its file items.
    public init(generation: UInt64, items: [Item]) {
        self.generation = generation
        self.items = items
    }

    /// No current offer — an empty working set.
    public static let empty = ClipboardFileProviderManifest(generation: 0, items: [])

    /// The item matching an identifier, or `nil` if it isn't in the current offer
    /// (a stale identifier from a superseded generation).
    public func item(for identifier: String) -> Item? {
        guard let decoded = ClipboardFileProviderItemIdentifier.decode(identifier) else { return nil }
        return items.first {
            $0.generation == decoded.generation && $0.repIndex == decoded.repIndex
        }
    }
}

/// Failure reaching the shared app-group container.
enum ClipboardFileProviderContainerError: Error {
    /// The app-group container couldn't be resolved (e.g. the entitlement is
    /// absent, as in a CI test host).
    case containerUnavailable
}

/// Locates the shared app-group container and reads/writes the offer manifest
/// for one direction's config.
///
/// `containerURL(forSecurityApplicationGroupIdentifier:)` may return a URL whose
/// directory isn't actually accessible (per Apple's docs), so writes are
/// fallible and reads degrade to `.empty`. Direction-bound: the app group and
/// the subdirectory come from the `ClipboardFileProviderConfig` it's built with,
/// so the guest and host containers never collide on a shared dev Mac.
public struct ClipboardFileProviderContainer: Sendable {
    private static let stagingDirectoryName = "staging"
    private static let manifestFilename = "clipboard-manifest.json"

    private let appGroupIdentifier: String
    private let directoryName: String

    /// Builds a container for one direction.
    public init(config: ClipboardFileProviderConfig) {
        self.appGroupIdentifier = config.appGroupIdentifier
        self.directoryName = config.containerDirectoryName
    }

    /// The shared app-group container directory, or `nil` if unavailable.
    public func containerURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    private func fileProviderDirectoryURL() -> URL? {
        containerURL()?.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Root for inbound File-Provider staging, inside the shared container so the
    /// sandboxed extension can read the staged bytes. `nil` when the container is
    /// unavailable.
    public func stagingRootURL() -> URL? {
        fileProviderDirectoryURL()?.appendingPathComponent(
            Self.stagingDirectoryName, isDirectory: true)
    }

    private func manifestURL() -> URL? {
        fileProviderDirectoryURL()?.appendingPathComponent(
            Self.manifestFilename, isDirectory: false)
    }

    /// Atomically writes the current offer manifest (container-app side).
    public func writeManifest(_ manifest: ClipboardFileProviderManifest) throws {
        guard let url = manifestURL() else {
            throw ClipboardFileProviderContainerError.containerUnavailable
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    /// Reads the current offer manifest (extension side); `.empty` when none is
    /// present or it can't be decoded.
    public func readManifest() -> ClipboardFileProviderManifest {
        guard let url = manifestURL(), let data = try? Data(contentsOf: url),
            let manifest = try? JSONDecoder().decode(ClipboardFileProviderManifest.self, from: data)
        else { return .empty }
        return manifest
    }
}
