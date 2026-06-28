import FileProvider
import Foundation
import KernovaKit
import UniformTypeIdentifiers
import os

// KernovaFileProvider — guest File Provider extension (issue #376).
//
// Serves host→guest clipboard *file* pastes as on-demand, dataless placeholders
// so a paste returns instantly and the bytes materialize on read via
// `fetchContents` — escaping Finder's 60s pasteboard-promise deadline
// (CLIPBOARD.md §2/§13).
//
// The extension is sandboxed and can't open a vsock, so it relays the byte pull
// to the guest agent over an app-group Mach service. The current offer's items
// come from a manifest the agent writes into the shared app-group container; the
// extension enumerates from it and `fetchContents` clones the agent-staged file
// (also in the shared container) into the domain's temporary directory before
// handing it to the system.

/// The principal class instantiated by the system per registered domain.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    static let logger = Logger(subsystem: "app.kernova.agent.fileprovider", category: "Extension")

    let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        Self.logger.notice(
            "FileProviderExtension init (domain=\(domain.identifier.rawValue, privacy: .public))")
    }

    func invalidate() {
        Self.logger.notice("FileProviderExtension invalidate")
    }

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        Self.logger.debug("item(for: \(identifier.rawValue, privacy: .public))")
        if identifier == .rootContainer {
            completionHandler(ClipboardRootItem(), nil)
        } else if let manifestItem = ClipboardFileProviderContainer.readManifest()
            .item(for: identifier.rawValue)
        {
            completionHandler(ClipboardFileItem(manifestItem: manifestItem), nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress()
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        Self.logger.notice(
            "fetchContents START (item=\(itemIdentifier.rawValue, privacy: .public))")
        let progress = Progress(totalUnitCount: 100)

        // The identifier carries the addressing; the manifest carries the metadata
        // for the returned item. A superseded item is gone from both → noSuchItem.
        guard let decoded = ClipboardFileProviderItemIdentifier.decode(itemIdentifier.rawValue),
            let manifestItem = ClipboardFileProviderContainer.readManifest()
                .item(for: itemIdentifier.rawValue)
        else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        // Relay the byte pull to the agent — the sandboxed extension can't open
        // vsock (CLIPBOARD.md §11). The system calls fetchContents off-thread with
        // no 60s deadline, so blocking on the reply is safe and lets the completion
        // handler run synchronously here.
        let connection = NSXPCConnection(
            machServiceName: ClipboardFileProviderRelayConfig.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: ClipboardFileProviderRelay.self)
        connection.resume()
        defer { connection.invalidate() }

        final class Outcome: @unchecked Sendable {
            var path: String?
            var error: Error?
        }
        let outcome = Outcome()
        let semaphore = DispatchSemaphore(value: 0)

        let proxy =
            connection.remoteObjectProxyWithErrorHandler { error in
                outcome.error = error
                semaphore.signal()
            } as? ClipboardFileProviderRelay
        guard let proxy else {
            completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
            return progress
        }

        proxy.fetchFile(generation: decoded.generation, repIndex: decoded.repIndex) { path, error in
            outcome.path = path
            outcome.error = error
            semaphore.signal()
        }
        semaphore.wait()

        guard let stagedPath = outcome.path else {
            Self.logger.error(
                "fetchContents relay failed: \(outcome.error?.localizedDescription ?? "unknown", privacy: .public)"
            )
            completionHandler(nil, nil, outcome.error ?? NSFileProviderError(.serverUnreachable))
            return progress
        }

        // Clone the agent-staged file (shared app-group container) into the
        // domain's temporary directory, which is guaranteed to be on the same
        // volume so the system can clone it into its replicated store. A same-
        // volume copy is an APFS clonefile — near-free — and hands the system a
        // disposable file, leaving the agent's staging cache free to evict.
        guard let manager = NSFileProviderManager(for: domain) else {
            completionHandler(nil, nil, NSFileProviderError(.providerNotFound))
            return progress
        }
        do {
            let tempDir = try manager.temporaryDirectoryURL()
            let destination = tempDir.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: stagedPath), to: destination)
            Self.logger.notice("fetchContents materialized \(manifestItem.byteCount, privacy: .public) bytes")
            progress.completedUnitCount = 100
            completionHandler(destination, ClipboardFileItem(manifestItem: manifestItem), nil)
        } catch {
            Self.logger.error(
                "fetchContents clone failed: \(error.localizedDescription, privacy: .public)")
            completionHandler(nil, nil, error)
        }
        return progress
    }

    // The clipboard domain is read-only — mutating operations are unsupported.

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) ->
            Void
    ) -> Progress {
        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
        return Progress()
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) ->
            Void
    ) -> Progress {
        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
        return Progress()
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        completionHandler(NSFileProviderError(.noSuchItem))
        return Progress()
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        ClipboardEnumerator(container: containerItemIdentifier)
    }
}

/// The domain's root container.
// RATIONALE: NSObject isn't Sendable, but the type is immutable, so the system
// calling in on several threads is safe.
final class ClipboardRootItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { "Kernova Clipboard" }
    var capabilities: NSFileProviderItemCapabilities { [.allowsReading, .allowsContentEnumerating] }
    var contentType: UTType { .folder }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data("1".utf8), metadataVersion: Data("1".utf8))
    }
}

/// One served file item, built from a manifest entry.
// RATIONALE: every stored property is an immutable `let` of a Sendable type, so
// the system reading it from any thread is safe.
final class ClipboardFileItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let size: Int
    /// Stored under a non-colliding name: `NSFileProviderItem.typeIdentifier` is
    /// deprecated/unavailable in favour of `contentType`, so a property named
    /// `typeIdentifier` would clash with the unavailable requirement.
    let representationUTI: String

    init(manifestItem: ClipboardFileProviderManifest.Item) {
        self.itemIdentifier = NSFileProviderItemIdentifier(manifestItem.itemIdentifier)
        self.parentItemIdentifier = .rootContainer
        self.filename = manifestItem.filename
        self.size = Int(clamping: manifestItem.byteCount)
        self.representationUTI = manifestItem.uti
        super.init()
    }

    var capabilities: NSFileProviderItemCapabilities { [.allowsReading] }
    var contentType: UTType { UTType(representationUTI) ?? .data }
    var documentSize: NSNumber? { NSNumber(value: size) }
    // The bytes and metadata of a given (generation, repIndex) item never change,
    // so a constant version is correct — and keeps fetchContents' returned
    // version matching the enumerated one (the framework requires the match).
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data("1".utf8), metadataVersion: Data("1".utf8))
    }
}

/// Enumerates the domain's contents from the current offer manifest.
final class ClipboardEnumerator: NSObject, NSFileProviderEnumerator {
    let container: NSFileProviderItemIdentifier

    init(container: NSFileProviderItemIdentifier) {
        self.container = container
        super.init()
    }

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
    ) {
        if container == .rootContainer || container == .workingSet {
            let items = ClipboardFileProviderContainer.readManifest().items.map {
                ClipboardFileItem(manifestItem: $0)
            }
            observer.didEnumerate(items)
        }
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
    ) {
        // RATIONALE: the working set is fully derived from the manifest, so rather
        // than track per-item diffs the enumerator forces a fresh full enumeration
        // whenever the offer generation changed (the anchor differs) — always
        // consistent for a single tiny item, and cheap. An unchanged anchor means
        // no changes.
        if anchor.rawValue == Self.currentAnchor().rawValue {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
        } else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.currentAnchor())
    }

    /// Anchor encoding the current offer generation, so a new offer invalidates
    /// the system's cached anchor and triggers a re-enumeration.
    private static func currentAnchor() -> NSFileProviderSyncAnchor {
        let generation = ClipboardFileProviderContainer.readManifest().generation
        return NSFileProviderSyncAnchor(Data("gen-\(generation)".utf8))
    }
}
