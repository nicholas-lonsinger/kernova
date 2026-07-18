import AppKit
import KernovaKit
import UniformTypeIdentifiers
import os

/// Writes a clipboard service's current content to the host `NSPasteboard`,
/// lazily — the window-independent home of the "Copy to Mac" write-back path.
///
/// This is the single inbound-publication mechanism (CLIPBOARD.md §4, one data
/// plane): both the clipboard window's "Copy to Mac" button and the automatic
/// passthrough coordinator publish through the *same* instance, so guest content
/// reaches the host pasteboard by one path regardless of who triggers it. The
/// window used to own this logic, but passthrough must publish with the window
/// closed, so it lives here and is owned per-VM by `VMInstance`.
///
/// Publication is lazy (CLIPBOARD.md §3): each written item promises its types
/// through a `LazyClipboardDataProvider` whose bytes are read only when a
/// destination pastes. The providers outlive this object — a paste can land long
/// after the window (or the VM) is gone — so they are handed to the app-scoped
/// `LazyClipboardProviderRegistry` on a successful write.
///
/// Every write is marked `.currentHostOnly` (CLIPBOARD.md §10): guest content
/// becomes host-owned data on arrival, so it must not be re-advertised to the
/// user's other Apple-Account-linked devices over Universal Clipboard.
@MainActor
final class HostClipboardPublisher {
    /// Label for the host-side clipboard staging root.
    ///
    /// Shared so `AppDelegate`'s launch-time orphan sweep targets the same temp
    /// directory this publisher (and the window's inbound intake) stage into. The
    /// staging never sweeps on window/VM teardown — that would invalidate a
    /// just-copied file URL still on the pasteboard — so orphans are reclaimed at
    /// launch instead, mirroring how the guest agent sweeps on start.
    static let stagingLabel = "host"

    /// Destination pasteboard for the write.
    ///
    /// `.general` in production; tests inject a private `NSPasteboard(name:)` to
    /// exercise the write/retention path without touching the developer's real
    /// clipboard, or a `HostWritePasteboard` fake to force a write failure.
    private let writePasteboard: any HostWritePasteboard

    /// Process-lifetime owner of the lazy data providers a write promises.
    ///
    /// A promised pasteboard item can be pasted long after the window closes, so
    /// the providers must outlive this object — they live in this app-scoped
    /// registry rather than on `self`.
    private let providerRegistry: LazyClipboardProviderRegistry

    /// Materializes inline/directory payloads to local temp files so a Finder
    /// paste creates real files.
    ///
    /// Recent generations are retained so a just-copied URL on the pasteboard
    /// stays valid across a couple more copies.
    private let staging = ClipboardFileStaging(label: HostClipboardPublisher.stagingLabel)

    /// Monotonic generation for the launch-swept staging root, bumped per publish
    /// so each supersedes older staged artifacts within the recency window.
    private var stagingGeneration: UInt64 = 1

    /// The write pasteboard's `changeCount` immediately after this publisher's
    /// most recent successful write, or `nil` before any write.
    ///
    /// A passthrough coordinator polling the same pasteboard reads this to
    /// recognize (and skip) the change its own inbound auto-publish — or a window
    /// "Copy to Mac" through this same publisher — produced, so guest content
    /// written to the host pasteboard is never re-forwarded back to the guest.
    private(set) var lastWriteChangeCount: Int?

    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "HostClipboardPublisher")

    init(
        writePasteboard: any HostWritePasteboard = NSPasteboard.general,
        providerRegistry: LazyClipboardProviderRegistry = .shared
    ) {
        self.writePasteboard = writePasteboard
        self.providerRegistry = providerRegistry
    }

    /// Materializes the service's current content and writes it to the host
    /// pasteboard as lazy promised items, returning the terminal outcome.
    ///
    /// Inline/preview/directory reps are pulled eagerly and grouped by the shared
    /// planner; every plain file rep rides its own lazy item whose File-Provider-
    /// vs-size-capped-sync routing is decided at paste time. The byte reads
    /// themselves are deferred into each item's provider closure (paste time). On a
    /// successful write the providers are handed to the app-scoped registry so a
    /// later paste is still served.
    func publish(from service: any ClipboardServicing) async -> HostPublishOutcome {
        let staging = self.staging
        let generation = stagingGeneration
        stagingGeneration += 1

        let copyItems = await service.materializeForCopy()
        var resolvedReps: [ClipboardContent.Representation] = []
        var lazyFiles: [(generation: UInt64, repIndex: Int)] = []
        var droppedReasons: [CopyToMacDropReason] = []
        for item in copyItems {
            switch item {
            case .resolved(let rep): resolvedReps.append(rep)
            case .lazyFile(let generation, let repIndex, _, _): lazyFiles.append((generation, repIndex))
            case .droppedFile(let reason): droppedReasons.append(reason)
            }
        }
        guard !resolvedReps.isEmpty || !lazyFiles.isEmpty else {
            return .nothingServed(reasons: droppedReasons)
        }

        // Eager reps go through the shared planner (inline grouping, image-file
        // staging, directory extraction). Each lazy file rep gets its own item
        // whose `.fileURL` is routed at paste time — File Provider first, else a
        // size-capped sync pull; only `VsockClipboardService` produces `.lazyFile`.
        var specs = await Self.hostPasteboardItems(
            for: ClipboardContent(representations: resolvedReps), generation: generation,
            staging: staging)
        if let fileProvider = service as? any HostClipboardFileRepProviding {
            specs += lazyFiles.map {
                Self.lazyFileSpec(
                    generation: $0.generation, repIndex: $0.repIndex, fileProvider: fileProvider)
            }
        }

        // `hostPasteboardItems` emits a spec only with a non-empty `types`, so an
        // empty `specs` means every resolved payload was dropped (e.g. a lone
        // folder that failed to extract). Surface that rather than clearing the
        // Mac clipboard to write nothing.
        guard !specs.isEmpty else {
            Self.logger.error("Host clipboard publish produced no pasteboard items (staging failed)")
            return .stagingFailed
        }

        // One lazy provider per item: its bytes are read only when a destination
        // pastes that type. Captures the registry (not self), so the provider's
        // lifetime is decoupled from this object.
        let registry = self.providerRegistry
        var providers: [LazyClipboardDataProvider] = []
        let items = specs.map { spec -> NSPasteboardItem in
            let item = NSPasteboardItem()
            let provider = LazyClipboardDataProvider(
                provide: spec.provide,
                onFinished: { provider in registry.release(provider) })
            item.setDataProvider(provider, forTypes: spec.types)
            providers.append(provider)
            return item
        }

        let pasteboard = writePasteboard
        // RATIONALE: `.currentHostOnly` (see class doc) is reset by the next
        // `prepareForNewContents`/`clearContents`, so it must be (re)applied at
        // this single inbound-publication choke point on every write, not once
        // at init.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.writeObjects(items) else {
            // The write failed, so the providers were never retained — the local
            // array drops them and no finish callback fires.
            Self.logger.error("NSPasteboard.writeObjects failed for host clipboard publish")
            return .writeFailed
        }
        // The promise is live now, so hand provider ownership to the registry;
        // a paste can land long after this returns, including after the window closes.
        providerRegistry.retain(providers)
        let changeCount = pasteboard.changeCount
        lastWriteChangeCount = changeCount
        let representationCount = resolvedReps.count + lazyFiles.count
        Self.logger.info(
            "Published clipboard buffer to host pasteboard (\(representationCount, privacy: .public) reps, \(items.count, privacy: .public) items, \(droppedReasons.count, privacy: .public) dropped)"
        )
        return .written(
            representationCount: representationCount, droppedReasons: droppedReasons,
            changeCount: changeCount)
    }

    /// One pasteboard item to write: the types it promises and a closure that
    /// lazily serves the bytes for each requested type.
    ///
    /// The spec is the lazy counterpart of an eager `[(type, data)]` item — the
    /// byte read is deferred into `provide`, which the `LazyClipboardDataProvider`
    /// invokes only when a destination actually pastes that type.
    struct PasteboardItemSpec: Sendable {
        let types: [NSPasteboard.PasteboardType]
        let provide: @Sendable (NSPasteboard.PasteboardType) -> Data?
    }

    /// A pasteboard item for a lazy plain-file rep whose File-Provider-vs-sync
    /// routing is decided at paste time: `provide(.fileURL)` calls
    /// `copyToMacFileURL`, which tries the host File Provider first (a dataless
    /// placeholder that materializes on read, no deadline) and falls back to a
    /// size-capped synchronous pull when the File Provider is off.
    ///
    /// On the sync-fallback path the pull runs synchronously on the main thread
    /// (the pasteboard server's `provideData` callback), blocking it while the
    /// stream receiver delivers off-main — the same bridge the File Provider relay
    /// uses. The offer's sync-bound total is size-capped (`maxDeadlineSafeFileBytes`)
    /// so the pull + stage completes within the OS paste deadline.
    nonisolated private static func lazyFileSpec(
        generation: UInt64, repIndex: Int, fileProvider: any HostClipboardFileRepProviding
    ) -> PasteboardItemSpec {
        PasteboardItemSpec(types: [.fileURL]) { type in
            guard type == .fileURL else { return nil }
            guard let url = fileProvider.copyToMacFileURL(generation: generation, repIndex: repIndex)
            else { return nil }
            return Data(url.absoluteString.utf8)
        }
    }

    /// Builds the per-item provider specs to promise on the host pasteboard for
    /// the eagerly-resolved `content`, while deferring inline byte reads to paste
    /// time.
    ///
    /// A single inline item promises every inline (filename-less) representation;
    /// each file payload becomes its own item promising exactly one `.fileURL`
    /// (and, for an image file, its inline image bytes too). One `.fileURL` per
    /// item is what a Finder paste needs to create N files — a single item holds
    /// only one value per type, so several file URLs in one item would collide.
    /// Mirrors the guest agent's inbound promise grouping. (`content` carries only
    /// resolved reps — the lazy single file rep is added by the caller via
    /// `lazyFileSpec`.)
    ///
    /// Internal (not `private`) so `@testable import` can exercise this pure
    /// grouping/staging step — and each spec's `provide` closure — directly.
    nonisolated static func hostPasteboardItems(
        for content: ClipboardContent, generation: UInt64, staging: ClipboardFileStaging
    ) async -> [PasteboardItemSpec] {
        // The grouping decision (one shared inline item; one item per file
        // payload; UTI dedup) is the shared planner — the single source of truth
        // both sides of the bridge use. This side maps each planned item to a lazy
        // `PasteboardItemSpec`: a File Provider placeholder / extracted-directory
        // `.fileURL` is a stable URL used as-is, an inline-and-named image file is
        // staged to a sink, and inline byte reads are deferred to paste time.
        let descriptors = content.representations.map {
            ClipboardRepresentationDescriptor(
                uti: $0.uti, filename: $0.filename,
                isInline: $0.shouldInlineOnPasteboard, isPromisable: true)
        }
        let plan = ClipboardPasteboardItemPlan.plan(for: descriptors)

        var specs: [PasteboardItemSpec] = []
        for item in plan.items {
            if item.types.contains(where: \.isFileURL) {
                // A file payload — one item promising exactly one `.fileURL` (plus
                // inline image bytes for an image file). All of an item's types
                // share one backing rep. Same-named files get distinct staged URLs
                // from `ClipboardFileStaging`; the `.fileURL` is resolved now (eager
                // staging), the image bytes served on demand.
                let representation = content.representations[item.types[0].representationIndex]
                var types: [NSPasteboard.PasteboardType] = []
                // The planner emits the content (image) UTI before `.fileURL` iff the
                // rep inlines — promise that flavor from the same durable staged file.
                let imageType = item.types.first { !$0.isFileURL }
                    .map { NSPasteboard.PasteboardType($0.uti) }
                if let imageType { types.append(imageType) }

                // Resolve the pasteboard `.fileURL`: a File Provider placeholder's
                // stable domain URL, or an inline image file written to a durable
                // sink. The image flavor reads the SAME staged file — reading
                // `representation.fileURL` lazily could vend empty bytes once a
                // transient source is swept, the window-survival case the provider
                // registry exists to support.
                let stagedURL = stagedFileURL(
                    for: representation, generation: generation, staging: staging)
                let fileURLData = stagedURL.map { Data($0.absoluteString.utf8) }
                if fileURLData != nil { types.append(.fileURL) }

                guard !types.isEmpty else { continue }
                specs.append(
                    PasteboardItemSpec(types: types) { type in
                        if type == .fileURL { return fileURLData }
                        if type == imageType {
                            if let stagedURL,
                                let data = try? Data(contentsOf: stagedURL, options: .mappedIfSafe)
                            {
                                return data
                            }
                            // Staging produced no durable file — fall back to the
                            // rep's own bytes (resident, or a best-effort URL read).
                            return inlineData(for: representation)
                        }
                        return nil
                    })
            } else {
                // The shared inline item: promise every inline rep's content UTI,
                // reading the bytes lazily only when a destination pastes that type.
                var inlineByType: [NSPasteboard.PasteboardType: ClipboardContent.Representation] = [:]
                var inlineTypes: [NSPasteboard.PasteboardType] = []
                for promised in item.types {
                    let type = NSPasteboard.PasteboardType(promised.uti)
                    inlineByType[type] = content.representations[promised.representationIndex]
                    inlineTypes.append(type)
                }
                // Snapshot to a `let` so the @Sendable provider closure captures an
                // immutable map rather than the mutable `var` built above.
                let inlineReps = inlineByType
                specs.append(
                    PasteboardItemSpec(types: inlineTypes) { type in
                        inlineReps[type].flatMap(inlineData(for:))
                    })
            }
        }
        return specs
    }

    /// Resident bytes to inline for a representation, memory-mapped rather than
    /// read whole so a multi-GB image is never loaded into the heap.
    ///
    /// The bytes page in on demand and the OS can evict them under pressure. The
    /// caller gates this to image payloads (`shouldInlineOnPasteboard`), so there
    /// is no size ceiling to apply (CLIPBOARD.md §1).
    nonisolated private static func inlineData(
        for representation: ClipboardContent.Representation
    ) -> Data? {
        if let resident = representation.inMemoryData {
            return resident
        }
        if let url = representation.fileURL {
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        }
        return nil
    }

    /// Returns the pasteboard `public.file-url` for a resolved file payload.
    ///
    /// A directory payload is extracted from its streamed `.aar` into a real
    /// folder under the launch-swept root so a Finder paste recreates the tree. An
    /// inline-and-named payload (image file) is written to a fresh sink so its
    /// `.fileURL` outlives the VM teardown.
    nonisolated private static func stagedFileURL(
        for representation: ClipboardContent.Representation, generation: UInt64,
        staging: ClipboardFileStaging
    ) -> URL? {
        if representation.isDirectory {
            // A directory rep's bytes are an `.aar` of the tree. Extract it into a
            // real folder under the launch-swept root so a Finder paste recreates
            // the tree, not the archive file. The shared helper (also used by the
            // guest agent) does the free-space floor check + extract.
            return ClipboardDirectoryArchive.extractedDirectoryURL(
                for: representation, into: staging, generation: generation)
        }
        if let existing = representation.fileURL {
            // A File Provider placeholder already has a stable domain URL (its bytes
            // materialize lazily on read); use it as-is. A rare spilled inline file
            // simply keeps its transient URL.
            return existing
        }
        guard let data = representation.inMemoryData,
            let sink = try? staging.makeSink(
                generation: generation, filename: representation.filename)
        else { return nil }
        do {
            try sink.write(data)
            return try sink.commit()
        } catch {
            // Don't offer a truncated file — abort the partial stage.
            sink.abort()
            return nil
        }
    }
}

/// The terminal state of a `HostClipboardPublisher.publish(from:)`.
///
/// The clipboard window maps each case to a transient status message; the
/// passthrough coordinator reads `didWrite`/`postWriteChangeCount` for echo
/// suppression.
enum HostPublishOutcome {
    /// No representation could be served — every file payload was dropped and
    /// there was no inline/lazy content. `reasons` explains why (most-actionable
    /// first).
    case nothingServed(reasons: [CopyToMacDropReason])
    /// Reps resolved, but building their pasteboard items produced none (e.g. a
    /// lone directory whose archive couldn't be extracted).
    case stagingFailed
    /// The write succeeded. `representationCount` items were placed;
    /// `droppedReasons` lists payloads that couldn't be served alongside them;
    /// `changeCount` is the write pasteboard's change count right after the write.
    case written(
        representationCount: Int, droppedReasons: [CopyToMacDropReason], changeCount: Int)
    /// `writeObjects` returned false — nothing was placed.
    case writeFailed

    /// `true` only when the write landed on the pasteboard.
    var didWrite: Bool {
        if case .written = self { return true }
        return false
    }

    /// The pasteboard's change count right after a successful write, else `nil` —
    /// the echo-suppression key for a coordinator polling the same pasteboard.
    var postWriteChangeCount: Int? {
        if case .written(_, _, let changeCount) = self { return changeCount }
        return nil
    }
}
