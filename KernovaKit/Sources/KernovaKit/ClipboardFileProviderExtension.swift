import FileProvider
import Foundation
import UniformTypeIdentifiers
import os

// Shared clipboard File Provider extension (issues #376 guest / #424 host).
//
// Serves clipboard *file* pastes as on-demand, dataless placeholders so a paste
// returns instantly and the bytes materialize on read via `fetchContents` —
// escaping Finder's 60s pasteboard-promise deadline (CLIPBOARD.md §2/§13).
//
// The extension is sandboxed and can't open a vsock, so it relays the byte pull
// to the owning process (the guest agent, or the main app via its broker) over
// an app-group Mach service. The current offer's items come from a manifest the
// owner writes into the shared app-group container; the extension enumerates
// from it and `fetchContents` clones the owner-staged file (also in the shared
// container) into the domain's temporary directory before handing it to the
// system.
//
// Direction-agnostic: all addressing comes from `directionConfig`. Each appex
// subclasses this and overrides `directionConfig` with its direction; the
// subclass is the bundle's `NSExtensionPrincipalClass`, so the principal class
// stays in the appex module (its runtime name unchanged) while all logic lives
// here, the single source of truth.

/// The shared principal-class base.
///
/// Subclasses override `directionConfig`. The base conforms to
/// `NSFileProviderReplicatedExtension` so the protocol's witnesses (and whatever
/// Obj-C exposure the framework needs) live on the conforming type; subclasses
/// inherit the conformance, all method implementations, and the
/// `required init(domain:)`, and supply only their direction.
open class ClipboardFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    /// The direction this extension serves.
    ///
    /// Abstract — every concrete appex subclass must override it (the base is
    /// never the principal class).
    open class var directionConfig: ClipboardFileProviderConfig {
        preconditionFailure(
            "ClipboardFileProviderExtension subclasses must override directionConfig")
    }

    /// The File Provider domain the system instantiated this extension for.
    public let domain: NSFileProviderDomain
    let config: ClipboardFileProviderConfig
    let store: ClipboardFileProviderContainer
    let logger: Logger

    /// Instantiated by the system per registered domain; configures itself from
    /// the subclass's `directionConfig`.
    public required init(domain: NSFileProviderDomain) {
        let config = Self.directionConfig
        self.domain = domain
        self.config = config
        self.store = ClipboardFileProviderContainer(config: config)
        self.logger = Logger(subsystem: config.extensionLoggerSubsystem, category: "Extension")
        super.init()
        logger.notice(
            "FileProviderExtension init (domain=\(domain.identifier.rawValue, privacy: .public))")
    }

    open func invalidate() {
        logger.notice("FileProviderExtension invalidate")
    }

    open func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        logger.debug("item(for: \(identifier.rawValue, privacy: .public))")
        if identifier == .rootContainer {
            completionHandler(ClipboardRootItem(displayName: config.domainDisplayName), nil)
        } else if let manifestItem = store.readManifest().item(for: identifier.rawValue) {
            completionHandler(ClipboardFileItem(manifestItem: manifestItem), nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress()
    }

    open func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        logger.debug("fetchContents START (item=\(itemIdentifier.rawValue, privacy: .public))")
        let progress = Progress(totalUnitCount: 100)

        // The identifier carries the addressing; the manifest carries the metadata
        // for the returned item. A superseded item is gone from both → noSuchItem.
        guard let decoded = ClipboardFileProviderItemIdentifier.decode(itemIdentifier.rawValue),
            let manifestItem = store.readManifest().item(for: itemIdentifier.rawValue)
        else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        // Relay the byte pull to the owner — the sandboxed extension can't open
        // vsock (CLIPBOARD.md §11). The system calls fetchContents off-thread with
        // no 60s deadline, so blocking on the reply is safe and lets the completion
        // handler run synchronously here.
        let connection = NSXPCConnection(machServiceName: config.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: ClipboardFileProviderRelay.self)
        // Validate the relay vendor when the direction requires it (the host pins
        // the main app, which now vends …xpc directly as a launchd agent; the guest
        // leaves it nil — see the config doc and #145). Non-throwing: arms a
        // framework-enforced check, so an impostor vendor has this connection's calls
        // invalidated below.
        if let requirement = config.relayCodeSigningRequirement {
            connection.setCodeSigningRequirement(requirement)
        }
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
            logger.error(
                "fetchContents relay failed: \(outcome.error?.localizedDescription ?? "unknown", privacy: .public)"
            )
            completionHandler(nil, nil, outcome.error ?? NSFileProviderError(.serverUnreachable))
            return progress
        }

        // Clone the owner-staged file (shared app-group container) into the
        // domain's temporary directory, which is guaranteed to be on the same
        // volume so the system can clone it into its replicated store. A same-
        // volume copy is an APFS clonefile — near-free — and hands the system a
        // disposable file, leaving the owner's staging cache free to evict.
        guard let manager = NSFileProviderManager(for: domain) else {
            completionHandler(nil, nil, NSFileProviderError(.providerNotFound))
            return progress
        }
        do {
            let tempDir = try manager.temporaryDirectoryURL()
            let destination = tempDir.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: stagedPath), to: destination)
            logger.notice("fetchContents materialized \(manifestItem.byteCount, privacy: .public) bytes")
            progress.completedUnitCount = 100
            completionHandler(destination, ClipboardFileItem(manifestItem: manifestItem), nil)
        } catch {
            logger.error("fetchContents clone failed: \(error.localizedDescription, privacy: .public)")
            completionHandler(nil, nil, error)
        }
        return progress
    }

    // The clipboard domain is read-only — mutating operations are unsupported.

    open func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler:
            @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) ->
            Void
    ) -> Progress {
        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
        return Progress()
    }

    open func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler:
            @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) ->
            Void
    ) -> Progress {
        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
        return Progress()
    }

    open func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        completionHandler(NSFileProviderError(.noSuchItem))
        return Progress()
    }

    open func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        logger.debug("enumerator(for: \(containerItemIdentifier.rawValue, privacy: .public))")
        return ClipboardEnumerator(container: containerItemIdentifier, store: store, logger: logger)
    }
}

/// The domain's root container.
// RATIONALE: NSObject isn't Sendable, but the type is immutable, so the system
// calling in on several threads is safe.
final class ClipboardRootItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    private let displayName: String

    init(displayName: String) {
        self.displayName = displayName
        super.init()
    }

    var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { displayName }
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

    // RATIONALE: the clipboard domain is conceptually read-only (it never syncs
    // edits back), but advertising only `.allowsReading` makes the system present
    // the item — and the file pasted from it — as **locked** (a padlock badge and
    // "Item is locked" on delete). Advertise full capabilities so the pasted copy
    // is an ordinary file the user owns; the mutating extension methods still
    // reject (the placeholder is transient and copied out, never edited in place).
    var capabilities: NSFileProviderItemCapabilities { .allowsAll }
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
    private let store: ClipboardFileProviderContainer
    private let logger: Logger

    init(
        container: NSFileProviderItemIdentifier, store: ClipboardFileProviderContainer,
        logger: Logger
    ) {
        self.container = container
        self.store = store
        self.logger = logger
        super.init()
    }

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
    ) {
        if container == .rootContainer || container == .workingSet {
            let items = store.readManifest().items.map { ClipboardFileItem(manifestItem: $0) }
            logger.debug(
                "enumerateItems(\(self.container.rawValue, privacy: .public)) → \(items.count, privacy: .public) item(s)"
            )
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
        if anchor.rawValue == currentAnchor().rawValue {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
        } else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(currentAnchor())
    }

    /// Anchor encoding the current offer generation, so a new offer invalidates
    /// the system's cached anchor and triggers a re-enumeration.
    private func currentAnchor() -> NSFileProviderSyncAnchor {
        let generation = store.readManifest().generation
        return NSFileProviderSyncAnchor(Data("gen-\(generation)".utf8))
    }
}
