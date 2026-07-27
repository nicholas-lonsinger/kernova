import FileProvider
import Foundation
import UniformTypeIdentifiers
import os

// Shared clipboard File Provider extension.
//
// Serves clipboard *file* pastes as on-demand, dataless placeholders so a paste
// returns instantly and the bytes materialize on read via `fetchContents` —
// escaping Finder's 60s pasteboard-promise deadline (CLIPBOARD.md §2/§13). The
// extension is sandboxed and can't open a vsock, so `fetchContents` relays the
// byte pull to the owning process over `NSFileProviderServicing`; the current
// offer's items come from a manifest the owner writes into the app group.

/// The shared principal-class base.
///
/// Subclasses override `directionConfig` and inherit the
/// `NSFileProviderReplicatedExtension` conformance, every method
/// implementation, and `required init(domain:)`.
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
    /// `makeListenerEndpoint()` calls.
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
        // Tear down the servicing endpoint so the owner's connection drops and it
        // reconnects to the replacement instance, rather than re-handshaking with
        // this dead instance's zombie source.
        serviceSource.invalidate()
    }

    // MARK: - NSFileProviderServicing

    /// Vends the single anonymous-XPC service source the owner connects to so it
    /// can be called back at `fetchContents`.
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
        } else if let item = Self.item(for: identifier.rawValue, in: store.readManifest()) {
            completionHandler(item, nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress()
    }

    /// Builds the `NSFileProviderItem` for a manifest identifier — a flat file, a
    /// directory rep's folder root, or one of its tree nodes — or `nil` when it
    /// isn't in the current offer.
    static func item(
        for rawIdentifier: String, in manifest: FileProviderManifest
    ) -> NSFileProviderItem? {
        switch manifest.resolve(rawIdentifier) {
        case .flatFile(let item):
            return ClipboardFileItem(manifestItem: item)
        case .folderRoot(let folder):
            return ClipboardTreeItem(folderRoot: folder)
        case .node(let folder, let node):
            return ClipboardTreeItem(folder: folder, node: node)
        case .none:
            return nil
        }
    }

    open func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        logger.debug("fetchContents START (item=\(itemIdentifier.rawValue, privacy: .public))")
        // Only a byte-bearing regular file is fetched: a flat single-file rep, or
        // a file node within a directory rep's placeholder tree. A
        // directory/symlink node is resolved from metadata, never fetched.
        let manifest = store.readManifest()
        let target: (returnedItem: NSFileProviderItem, byteCount: UInt64, pull: FetchPull)
        switch manifest.resolve(itemIdentifier.rawValue) {
        case .flatFile(let item):
            target = (
                ClipboardFileItem(manifestItem: item), item.byteCount,
                .flat(generation: item.generation, repIndex: item.repIndex)
            )
        case .node(let folder, let node) where node.kind == .file:
            target = (
                ClipboardTreeItem(folder: folder, node: node), node.byteCount,
                .child(
                    generation: folder.generation, repIndex: folder.repIndex,
                    childSeq: node.childSeq, relativePath: node.relativePath)
            )
        default:
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }

        // `fetchContents` must return a `Progress`: it carries the fetch's
        // cancellation token (wired below), and the framework reads its
        // `kind`/`fileOperationKind` to present the item as a file download. The
        // bar is created at the declared size and completed in one step at
        // `materialize`; a zero-byte rep gets a unit of 1, since a 0/0 progress
        // reads as indeterminate.
        let totalUnitCount = target.byteCount > 0 ? Int64(clamping: target.byteCount) : 1
        let progress = Progress(totalUnitCount: totalUnitCount)
        progress.kind = .file
        progress.fileOperationKind = .downloading

        let returnedItem = target.returnedItem
        // Relay the byte pull to the owner over the servicing connection — the
        // sandboxed extension can't open vsock (CLIPBOARD.md §11). With no owner
        // connection live, the source rings the Darwin doorbell and completes once
        // the owner reconnects. This MUST stay async: the framework serialises the
        // owner's `getFileProviderConnection` behind an in-flight `fetchContents`,
        // so blocking here deadlocks the very reconnect we're waiting for.
        let completion: (Result<String, NSError>) -> Void = {
            [weak self, weak progress] result in
            guard let self else {
                completionHandler(nil, nil, NSFileProviderError(.providerNotFound))
                return
            }
            switch result {
            case .success(let stagedPath):
                self.materialize(
                    stagedPath: stagedPath, returnedItem: returnedItem, progress: progress,
                    completionHandler: completionHandler)
            case .failure(let error):
                // Finder's cancel button completes with `NSUserCancelledError` —
                // an expected outcome, not a fetch failure.
                if error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError {
                    self.logger.debug("fetchContents cancelled by user")
                } else {
                    self.logger.error(
                        "fetchContents relay failed: \(error.localizedDescription, privacy: .public)")
                }
                completionHandler(nil, nil, error)
            }
        }
        let cancellation: FileProviderPullCancellation
        switch target.pull {
        case .flat(let generation, let repIndex):
            cancellation = serviceSource.fetchStagedFile(
                generation: generation, repIndex: repIndex, completion: completion)
        case .child(let generation, let repIndex, let childSeq, let relativePath):
            cancellation = serviceSource.fetchStagedChild(
                generation: generation, repIndex: repIndex, childSeq: childSeq,
                relativePath: relativePath, completion: completion)
        }
        // Wire Finder's cancel button to the pull. The completion closure above
        // captures `progress` WEAKLY so this handler — which strongly holds
        // `cancellation` → the pull → that completion — can't form a retain cycle
        // back through `progress`. The system owns `progress` until the fetch
        // completes, so the weak ref is never nil inside the completion.
        progress.cancellationHandler = { cancellation.cancel() }
        return progress
    }

    /// Which relay pull backs a `fetchContents`: a flat single-file rep, or a
    /// child file within a directory rep's placeholder tree.
    private enum FetchPull {
        case flat(generation: UInt64, repIndex: Int)
        case child(generation: UInt64, repIndex: Int, childSeq: UInt32, relativePath: String)
    }

    /// Clones the owner-staged file into the domain's temporary directory and hands
    /// it to the system, completing the fetch.
    ///
    /// `progress` is optional because the call site captures it weakly to avoid a
    /// cancellation retain cycle; see `fetchContents`.
    private func materialize(
        stagedPath: String, returnedItem: NSFileProviderItem, progress: Progress?,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) {
        // The domain's temporary directory is guaranteed to be on the same volume
        // as the system's replicated store, so this copy is an APFS clonefile and
        // the owner's staging cache stays free to evict.
        guard let manager = NSFileProviderManager(for: domain) else {
            completionHandler(nil, nil, NSFileProviderError(.providerNotFound))
            return
        }
        do {
            let tempDir = try manager.temporaryDirectoryURL()
            let destination = tempDir.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: stagedPath), to: destination)
            logger.notice(
                "fetchContents materialized \(returnedItem.documentSize??.int64Value ?? 0, privacy: .public) bytes"
            )
            // The bar is never advanced per chunk, so this terminal set is the
            // only completion the system's `Progress` receives.
            if let progress { progress.completedUnitCount = progress.totalUnitCount }
            completionHandler(destination, returnedItem, nil)
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
// Immutable, so `@unchecked Sendable` is safe here.
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
// Immutable `let` properties only, so `@unchecked Sendable` is safe here.
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

    // RATIONALE: advertising only `.allowsReading` — which the read-only clipboard
    // domain otherwise argues for — makes the system present the item, and the file
    // pasted from it, as **locked**: a padlock badge and "Item is locked" on delete.
    // Full capabilities keep the pasted copy an ordinary file the user owns; the
    // mutating extension methods still reject in-place edits. Spelled out rather
    // than `.allowsAll`, deprecated in macOS 12.
    var capabilities: NSFileProviderItemCapabilities {
        [.allowsReading, .allowsWriting, .allowsReparenting, .allowsRenaming, .allowsTrashing, .allowsDeleting]
    }
    var contentType: UTType { UTType(representationUTI) ?? .data }
    var documentSize: NSNumber? { NSNumber(value: size) }
    // The bytes of a given item identifier never change, so a constant version is
    // correct and keeps fetchContents' returned version matching the enumerated
    // one (the framework requires the match). It relies on the identifier being
    // unique per offer ACROSS owner sessions (the session salt): with a colliding
    // identifier fileproviderd sees no change and serves the stale placeholder's
    // bytes with `shouldFetch:false`.
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data("1".utf8), metadataVersion: Data("1".utf8))
    }
}

/// One node of a directory rep's placeholder tree — the folder root, a
/// subdirectory, a file, or a symlink (`clipboard.dirtree.v1`).
///
/// `RATIONALE:` every container is served with a plain `.folder` contentType even
/// when the manifest marks it a package (.app/.rtfd): a package-conforming type
/// makes the system fetch the container as an atomic *file* instead of
/// enumerating its children, which a placeholder tree cannot serve (observed
/// live: a pasted `.app` failed with Finder error -36). The pasted copy still
/// lands as a package on disk.
// Immutable `let` properties only, so `@unchecked Sendable` is safe here.
final class ClipboardTreeItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    private let isDirectory: Bool
    private let byteCount: Int
    private let symlinkTarget: String?
    private let posixPermissions: UInt32
    private let modificationDate: Date?
    private let directChildCount: Int?

    /// The folder root of a directory rep.
    init(folderRoot folder: FileProviderManifest.FolderRep) {
        self.itemIdentifier = NSFileProviderItemIdentifier(folder.rootIdentifier)
        self.parentItemIdentifier = .rootContainer
        self.filename = folder.filename
        self.contentType = .folder
        self.isDirectory = true
        self.byteCount = 0
        self.symlinkTarget = nil
        self.posixPermissions = 0
        self.modificationDate = Self.date(fromMillis: folder.mtimeMs)
        self.directChildCount = folder.nodes.filter { $0.parentChildSeq == 0 }.count
        super.init()
    }

    /// A descendant node of a directory rep.
    init(folder: FileProviderManifest.FolderRep, node: FileProviderManifest.FolderRep.Node) {
        self.itemIdentifier = NSFileProviderItemIdentifier(folder.identifier(for: node))
        // Parent is the folder root when `parentChildSeq == 0`, else the parent node.
        self.parentItemIdentifier =
            node.parentChildSeq == 0
            ? NSFileProviderItemIdentifier(folder.rootIdentifier)
            : NSFileProviderItemIdentifier(
                FileProviderItemIdentifier.makeNode(
                    sessionSalt: folder.sessionSalt, generation: folder.generation,
                    repIndex: folder.repIndex, childSeq: node.parentChildSeq))
        self.filename = node.filename
        switch node.kind {
        case .symlink:
            self.contentType = .symbolicLink
            self.symlinkTarget = node.symlinkTarget
            self.isDirectory = false
        case .directory:
            self.contentType = .folder
            self.symlinkTarget = nil
            self.isDirectory = true
        case .file:
            self.contentType = UTType(node.uti) ?? .data
            self.symlinkTarget = nil
            self.isDirectory = false
        }
        self.byteCount = Int(clamping: node.byteCount)
        self.posixPermissions = node.posixPermissions
        self.modificationDate = Self.date(fromMillis: node.mtimeMs)
        self.directChildCount =
            node.kind == .directory
            ? folder.nodes.filter { $0.parentChildSeq == node.childSeq }.count : nil
        super.init()
    }

    private static func date(fromMillis millis: Int64) -> Date? {
        guard millis > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    // Full capabilities so the pasted copy is an ordinary file/folder the user
    // owns rather than a locked File Provider item; see `ClipboardFileItem`.
    var capabilities: NSFileProviderItemCapabilities {
        var caps: NSFileProviderItemCapabilities = [
            .allowsReading, .allowsWriting, .allowsReparenting, .allowsRenaming, .allowsTrashing,
            .allowsDeleting,
        ]
        if isDirectory { caps.insert(.allowsContentEnumerating) }
        return caps
    }

    var documentSize: NSNumber? { isDirectory ? nil : NSNumber(value: byteCount) }

    var childItemCount: NSNumber? { directChildCount.map { NSNumber(value: $0) } }

    var symlinkTargetPath: String? { symlinkTarget }

    var contentModificationDate: Date? { modificationDate }

    /// Preserves the executable bit, critical for a pasted app bundle's binaries.
    ///
    /// A `0` permission set (unknown) degrades to readable/writable.
    var fileSystemFlags: NSFileProviderFileSystemFlags {
        guard !isDirectory else { return [.userReadable, .userWritable] }
        var flags: NSFileProviderFileSystemFlags = [.userReadable, .userWritable]
        if posixPermissions & 0o111 != 0 { flags.insert(.userExecutable) }
        return flags
    }

    // Constant for the same reason as `ClipboardFileItem.itemVersion`.
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
        let manifest = store.readManifest()
        if container == .rootContainer || container == .workingSet {
            let (files, folderRoots) = manifest.rootEntries()
            var items: [NSFileProviderItem] = files.map { ClipboardFileItem(manifestItem: $0) }
            items += folderRoots.map { ClipboardTreeItem(folderRoot: $0) }
            logger.debug(
                "enumerateItems(\(self.container.rawValue, privacy: .public)) → \(items.count, privacy: .public) root item(s)"
            )
            observer.didEnumerate(items)
        } else if let children = manifest.children(ofContainer: container.rawValue) {
            let items = children.map { ClipboardTreeItem(folder: $0.0, node: $0.1) }
            logger.debug(
                "enumerateItems(\(self.container.rawValue, privacy: .public)) → \(items.count, privacy: .public) child item(s)"
            )
            observer.didEnumerate(items)
        }
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
    ) {
        // The working set is fully derived from the manifest, so a changed anchor
        // forces a fresh full enumeration instead of per-item diffs.
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
