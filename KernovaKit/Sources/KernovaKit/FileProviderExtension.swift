import FileProvider
import Foundation
import UniformTypeIdentifiers
import os

// Shared clipboard File Provider extension (issues #376 guest / #424 host /
// #460 servicing migration).
//
// Serves clipboard *file* pastes as on-demand, dataless placeholders so a paste
// returns instantly and the bytes materialize on read via `fetchContents` —
// escaping Finder's 60s pasteboard-promise deadline (CLIPBOARD.md §2/§13).
//
// The extension is sandboxed and can't open a vsock, so it relays the byte pull
// to the owning process (the guest agent or the main app) over the canonical
// `NSFileProviderServicing` anonymous-XPC pipe: this extension conforms to
// `NSFileProviderServicing` and vends a `FileProviderServiceSource`
// whose anonymous listener endpoint the owner connects to. INVERTED wiring vs.
// the old Mach design — the owner is the XPC client and exports the relay; the
// extension calls it back through the accepted connection at `fetchContents`
// time (see `FileProviderServiceSource`). The current offer's items
// come from a manifest the owner writes into the shared app-group container; the
// extension enumerates from it and `fetchContents` clones the owner-staged file
// (also in the shared container) into the domain's temporary directory before
// handing it to the system.
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
open class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension,
    NSFileProviderServicing
{
    /// The direction this extension serves.
    ///
    /// Abstract — every concrete appex subclass must override it (the base is
    /// never the principal class).
    open class var directionConfig: FileProviderConfig {
        preconditionFailure(
            "FileProviderExtension subclasses must override directionConfig")
    }

    /// The File Provider domain the system instantiated this extension for.
    public let domain: NSFileProviderDomain
    let config: FileProviderConfig
    let store: FileProviderContainer
    let logger: Logger
    /// The single servicing endpoint vended to the owner.
    ///
    /// Created once so its anonymous listener endpoint is stable across
    /// `makeListenerEndpoint()` calls, and reachable from `fetchContents` for the
    /// byte-pull callback.
    let serviceSource: FileProviderServiceSource

    /// Instantiated by the system per registered domain; configures itself from
    /// the subclass's `directionConfig`.
    public required init(domain: NSFileProviderDomain) {
        let config = Self.directionConfig
        let logger = Logger(subsystem: config.extensionLoggerSubsystem, category: "Extension")
        self.domain = domain
        self.config = config
        self.store = FileProviderContainer(config: config)
        self.logger = logger
        self.serviceSource = FileProviderServiceSource(config: config, logger: logger)
        super.init()
        logger.notice(
            "FileProviderExtension init (domain=\(domain.identifier.rawValue, privacy: .public))")
    }

    open func invalidate() {
        logger.notice("FileProviderExtension invalidate")
    }

    // MARK: - NSFileProviderServicing

    /// Vends the single anonymous-XPC service source the owner connects to so it
    /// can be called back at `fetchContents` (#460).
    ///
    /// Domain-wide, so the per-item `itemIdentifier` is ignored.
    open func supportedServiceSources(
        for itemIdentifier: NSFileProviderItemIdentifier,
        completionHandler: @escaping ([NSFileProviderServiceSource]?, Error?) -> Void
    ) -> Progress {
        logger.debug(
            "supportedServiceSources(for: \(itemIdentifier.rawValue, privacy: .public))")
        completionHandler([serviceSource], nil)
        return Progress()
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
        // The identifier carries the addressing; the manifest carries the metadata
        // for the returned item. A superseded item is gone from both → noSuchItem.
        guard let decoded = FileProviderItemIdentifier.decode(itemIdentifier.rawValue),
            let manifestItem = store.readManifest().item(for: itemIdentifier.rawValue)
        else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }

        // A byte-denominated download progress (#426): the owner pushes per-chunk
        // `(bytesTransferred, totalBytes)` over the servicing connection during the
        // pull, so Finder renders a determinate download bar instead of the pulsing
        // indeterminate one. `kind`/`fileOperationKind` make the system present it as
        // a file download. `byteCount` is the manifest's declared size; a zero-byte
        // rep gets a unit of 1 (a 0/0 progress reads as indeterminate) and completes
        // instantly in `materialize`.
        let totalUnitCount = manifestItem.byteCount > 0 ? Int64(clamping: manifestItem.byteCount) : 1
        let progress = Progress(totalUnitCount: totalUnitCount)
        progress.kind = .file
        progress.fileOperationKind = .downloading

        // Relay the byte pull to the owner over the servicing connection — the
        // sandboxed extension can't open vsock (CLIPBOARD.md §11). INVERTED wiring:
        // the owner is the XPC client and exported the relay; we call it back
        // through the accepted connection (`serviceSource`). If no owner connection
        // is live, the source rings the Darwin doorbell and completes once the owner
        // reconnects. This MUST stay async — see `FileProviderServiceSource`:
        // the framework serialises the owner's `getFileProviderConnection` behind an
        // in-flight `fetchContents`, so blocking here would deadlock the very
        // reconnect we're waiting for. Return `progress` now; complete when the
        // staged path (or an error) lands.
        let cancellation = serviceSource.fetchStagedFile(
            generation: decoded.generation, repIndex: decoded.repIndex,
            // Advance the determinate bar from the owner's coalesced pushes (#426).
            // `progress` is captured weakly (same reason as the completion below —
            // the cancellation strongly retains this closure via the pull); the
            // system owns `progress` for the fetch's duration, so it's non-nil here.
            // Clamp to `totalUnitCount`: the final push carries bytes == total, and
            // `materialize` sets the terminal 100% regardless.
            onProgress: { [weak progress] bytesTransferred, _ in
                guard let progress else { return }
                progress.completedUnitCount = min(Int64(clamping: bytesTransferred), totalUnitCount)
            }
        ) { [weak self, weak progress] result in
            guard let self else {
                completionHandler(nil, nil, NSFileProviderError(.providerNotFound))
                return
            }
            switch result {
            case .success(let stagedPath):
                self.materialize(
                    stagedPath: stagedPath, manifestItem: manifestItem, progress: progress,
                    completionHandler: completionHandler)
            case .failure(let error):
                // A user cancellation (Finder's cancel button → `progress.cancel()`)
                // completes with Cocoa's `NSUserCancelledError`; log it at debug, not
                // error — it's an expected outcome, not a fetch failure.
                if error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError {
                    self.logger.debug("fetchContents cancelled by user")
                } else {
                    self.logger.error(
                        "fetchContents relay failed: \(error.localizedDescription, privacy: .public)")
                }
                completionHandler(nil, nil, error)
            }
        }
        // Wire Finder's cancel button to the pull. RATIONALE: the completion closure
        // above captures `progress` WEAKLY so this handler — which strongly holds
        // `cancellation` → the pull → that completion — can't form a retain cycle back
        // through `progress`. `progress` is alive whenever the completion runs (the
        // system owns it until the fetch completes), so the weak ref is never nil there.
        progress.cancellationHandler = { cancellation.cancel() }
        return progress
    }

    /// Clones the owner-staged file into the domain's temporary directory and hands
    /// it to the system, completing the fetch.
    ///
    /// Split out of `fetchContents` because the byte pull is now asynchronous, so
    /// materialization runs in the pull's completion rather than inline.
    ///
    /// `progress` is weak at the call site (to avoid a cancellation retain cycle —
    /// see `fetchContents`), so it's optional here; it's non-nil on the success path
    /// in practice because the system owns it until the fetch completes.
    private func materialize(
        stagedPath: String, manifestItem: FileProviderManifest.Item, progress: Progress?,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) {
        // Clone the owner-staged file (shared app-group container) into the domain's
        // temporary directory, which is guaranteed to be on the same volume so the
        // system can clone it into its replicated store. A same-volume copy is an
        // APFS clonefile — near-free — and hands the system a disposable file,
        // leaving the owner's staging cache free to evict.
        guard let manager = NSFileProviderManager(for: domain) else {
            completionHandler(nil, nil, NSFileProviderError(.providerNotFound))
            return
        }
        do {
            let tempDir = try manager.temporaryDirectoryURL()
            let destination = tempDir.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: stagedPath), to: destination)
            logger.notice("fetchContents materialized \(manifestItem.byteCount, privacy: .public) bytes")
            // Complete the byte-denominated bar (#426): a throttled final push may
            // have been coalesced away, and a zero-byte rep never pushed at all.
            if let progress { progress.completedUnitCount = progress.totalUnitCount }
            completionHandler(destination, ClipboardFileItem(manifestItem: manifestItem), nil)
        } catch {
            logger.error("fetchContents clone failed: \(error.localizedDescription, privacy: .public)")
            completionHandler(nil, nil, error)
        }
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

    init(manifestItem: FileProviderManifest.Item) {
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
    // Spelled out explicitly (rather than `.allowsAll`, deprecated in macOS 12) —
    // this is the exact set `.allowsAll` used to expand to.
    var capabilities: NSFileProviderItemCapabilities {
        [.allowsReading, .allowsWriting, .allowsReparenting, .allowsRenaming, .allowsTrashing, .allowsDeleting]
    }
    var contentType: UTType { UTType(representationUTI) ?? .data }
    var documentSize: NSNumber? { NSNumber(value: size) }
    // The bytes and metadata of a given item identifier never change, so a
    // constant version is correct — and keeps fetchContents' returned version
    // matching the enumerated one (the framework requires the match). This
    // relies on the identifier being unique per offer ACROSS owner sessions
    // (the session salt, #541): with a colliding identifier, fileproviderd
    // compares versions across two different offers, sees no change, and
    // serves the stale placeholder's bytes with `shouldFetch:false`.
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data("1".utf8), metadataVersion: Data("1".utf8))
    }
}

/// Enumerates the domain's contents from the current offer manifest.
final class ClipboardEnumerator: NSObject, NSFileProviderEnumerator {
    let container: NSFileProviderItemIdentifier
    private let store: FileProviderContainer
    private let logger: Logger

    init(
        container: NSFileProviderItemIdentifier, store: FileProviderContainer,
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
