import AppKit
import KernovaKit
import UniformTypeIdentifiers
import os

/// Writes a clipboard service's current content to the host `NSPasteboard`,
/// lazily — the window-independent home of the "Copy to Mac" write-back path.
///
/// The single inbound-publication mechanism (CLIPBOARD.md §4): the clipboard
/// window's button and the automatic passthrough coordinator both publish through
/// the same per-VM instance. Each item promises its types through a
/// `LazyClipboardDataProvider`, handed to the app-scoped provider registry on a
/// successful write — a paste can land long after the window, or the VM, is gone.
@MainActor
final class HostClipboardPublisher {
    /// Label for the host-side clipboard staging root.
    ///
    /// Never swept on window/VM teardown — that would invalidate a just-copied
    /// file URL still on the pasteboard — so `AppDelegate` reclaims orphans at
    /// launch instead.
    static let stagingLabel = "host"

    private let writePasteboard: any HostWritePasteboard

    /// Process-lifetime owner of the lazy data providers a write promises.
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

    /// The write pasteboard's `changeCount` immediately after the most recent
    /// successful write, or `nil` before any write (and after a retraction).
    ///
    /// A passthrough coordinator polling the same pasteboard skips this exact
    /// change, so guest content is never re-forwarded back to the guest.
    private(set) var lastWriteChangeCount: Int?

    /// Whether the most recent write carried promised (offer-addressed) items.
    ///
    /// Those are the only kind a supersession can strand, and so the only kind
    /// `retractPromisedWrite` retracts — a fully resolved write serves from
    /// local staging and survives the guest clipboard moving on.
    private var lastWriteWasPromised = false

    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "HostClipboardPublisher")

    init(
        writePasteboard: any HostWritePasteboard = NSPasteboard.general,
        providerRegistry: LazyClipboardProviderRegistry = .shared
    ) {
        self.writePasteboard = writePasteboard
        self.providerRegistry = providerRegistry
    }

    /// Builds the service's "Copy to Mac" items and writes them to the host
    /// pasteboard as lazy promised items, returning the terminal outcome.
    ///
    /// A live guest offer publishes from metadata alone — every promised rep's
    /// bytes are pulled at paste time through its provide closure — so nothing
    /// crosses the wire here; resolved (local) reps stage their bytes as before.
    func publish(from service: any ClipboardServicing) async -> HostPublishOutcome {
        let staging = self.staging
        let generation = stagingGeneration
        stagingGeneration += 1

        let copyItems = service.materializeForCopy()
        var resolvedReps: [ClipboardContent.Representation] = []
        var promises: [CopyToMacPromise] = []
        var droppedReasons: [CopyToMacDropReason] = []
        for item in copyItems {
            switch item {
            case .resolved(let rep): resolvedReps.append(rep)
            case .promised(let promise): promises.append(promise)
            case .droppedFile(let reason): droppedReasons.append(reason)
            }
        }
        guard !resolvedReps.isEmpty || !promises.isEmpty else {
            return .nothingServed(reasons: droppedReasons)
        }

        // Only `VsockClipboardService` produces `.promised`.
        var specs = await Self.hostPasteboardItems(
            for: ClipboardContent(representations: resolvedReps), generation: generation,
            staging: staging)
        if let repProvider = service as? any ClipboardPasteboardRepProviding {
            specs += Self.promisedItemSpecs(for: promises, provider: repProvider)
        }

        // An empty `specs` means every resolved payload was dropped (e.g. a lone
        // folder that failed to extract). Surface that rather than clearing the
        // Mac clipboard to write nothing.
        guard !specs.isEmpty else {
            Self.logger.error("Host clipboard publish produced no pasteboard items (staging failed)")
            return .stagingFailed
        }

        // Captures the registry, not `self`, so a provider's lifetime is
        // decoupled from this object.
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
        // `.currentHostOnly` (docs/CLIPBOARD.md §10) is per-write state, reset by
        // every `prepareForNewContents`/`clearContents`, so it is applied at this
        // single publication choke point rather than once at init.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.writeObjects(items) else {
            // The write failed, so the providers were never retained.
            Self.logger.error("NSPasteboard.writeObjects failed for host clipboard publish")
            return .writeFailed
        }
        providerRegistry.retain(providers)
        let changeCount = pasteboard.changeCount
        lastWriteChangeCount = changeCount
        lastWriteWasPromised = !promises.isEmpty
        let representationCount = resolvedReps.count + promises.count
        Self.logger.info(
            "Published clipboard buffer to host pasteboard (\(representationCount, privacy: .public) reps, \(items.count, privacy: .public) items, \(droppedReasons.count, privacy: .public) dropped)"
        )
        return .written(
            representationCount: representationCount, droppedReasons: droppedReasons,
            changeCount: changeCount)
    }

    /// `true` while the host pasteboard still holds this publisher's most recent
    /// write — nothing (the user included) has replaced it since.
    var pasteboardHoldsLastWrite: Bool {
        lastWriteChangeCount != nil && lastWriteChangeCount == writePasteboard.changeCount
    }

    /// Clears the host pasteboard when it still holds this publisher's most
    /// recent *promised* write, returning whether it did — the stale-promise
    /// retraction the clipboard service triggers when the guest's clipboard
    /// supersedes an offer whose promises can no longer be served.
    ///
    /// A pasteboard the user has since written over is theirs and is left
    /// untouched, as is a fully resolved write (it keeps serving from local
    /// staging).
    func retractPromisedWrite() -> Bool {
        guard lastWriteWasPromised, let lastWrite = lastWriteChangeCount,
            writePasteboard.changeCount == lastWrite
        else { return false }
        writePasteboard.clearContents()
        lastWriteChangeCount = nil
        lastWriteWasPromised = false
        Self.logger.notice("Retracted stale promised clipboard write from the host pasteboard")
        return true
    }

    /// One pasteboard item to write: the types it promises and a closure that
    /// lazily serves the bytes for each requested type.
    struct PasteboardItemSpec: Sendable {
        let types: [NSPasteboard.PasteboardType]
        let provide: @Sendable (NSPasteboard.PasteboardType) -> Data?
    }

    /// Builds the per-item provider specs for reps promised by offer coordinates —
    /// the same grouping the resolved path plans, driven by offer metadata alone.
    ///
    /// Each flavor's bytes are served at paste time: `.fileURL` through
    /// `copyToMacFileURL`, inline flavors through `copyToMacData`. The pull runs
    /// synchronously on the thread of the pasteboard server's `provideData`
    /// callback (usually main), blocking it while the stream receiver delivers
    /// off-main; the offer's paste-bound total is size-capped so the pull and
    /// stage complete within the OS paste deadline. A promise that withholds
    /// `.fileURL` (the over-cap refusal) never registers that type, so the paste
    /// finds no file flavor to fire rather than firing one that serves nothing.
    nonisolated static func promisedItemSpecs(
        for promises: [CopyToMacPromise], provider: any ClipboardPasteboardRepProviding
    ) -> [PasteboardItemSpec] {
        let descriptors = promises.map {
            ClipboardRepresentationDescriptor(
                uti: $0.uti, filename: $0.filename, isInline: $0.isInline, isPromisable: true)
        }
        let plan = ClipboardPasteboardItemPlan.plan(for: descriptors)
        return plan.items.compactMap { item -> PasteboardItemSpec? in
            var types: [NSPasteboard.PasteboardType] = []
            var routes: [NSPasteboard.PasteboardType: (promise: CopyToMacPromise, isFileURL: Bool)] =
                [:]
            for promisedType in item.types {
                let promise = promises[promisedType.representationIndex]
                if promisedType.isFileURL && promise.withholdsFileURL { continue }
                let type: NSPasteboard.PasteboardType =
                    promisedType.isFileURL ? .fileURL : .init(promisedType.uti)
                types.append(type)
                routes[type] = (promise, promisedType.isFileURL)
            }
            guard !types.isEmpty else { return nil }
            // Snapshot to a `let` so the @Sendable closure captures an immutable
            // map.
            let itemRoutes = routes
            return PasteboardItemSpec(types: types) { type in
                guard let route = itemRoutes[type] else { return nil }
                if route.isFileURL {
                    guard
                        let url = provider.copyToMacFileURL(
                            generation: route.promise.generation, repIndex: route.promise.repIndex)
                    else { return nil }
                    return Data(url.absoluteString.utf8)
                }
                return provider.copyToMacData(
                    generation: route.promise.generation, repIndex: route.promise.repIndex,
                    uti: route.promise.uti)
            }
        }
    }

    /// Builds the per-item provider specs to promise on the host pasteboard for
    /// the eagerly-resolved `content`, deferring inline byte reads to paste time.
    ///
    /// A single inline item promises every inline (filename-less) representation;
    /// each file payload becomes its own item promising exactly one `.fileURL`
    /// (and, for an image file, its inline image bytes too). One `.fileURL` per
    /// item is what a Finder paste needs to create N files — an item holds only
    /// one value per type, so several file URLs in one item would collide.
    nonisolated static func hostPasteboardItems(
        for content: ClipboardContent, generation: UInt64, staging: ClipboardFileStaging
    ) async -> [PasteboardItemSpec] {
        let descriptors = content.representations.map {
            ClipboardRepresentationDescriptor(
                uti: $0.uti, filename: $0.filename,
                isInline: $0.shouldInlineOnPasteboard, isPromisable: true)
        }
        let plan = ClipboardPasteboardItemPlan.plan(for: descriptors)

        var specs: [PasteboardItemSpec] = []
        for item in plan.items {
            if item.types.contains(where: \.isFileURL) {
                // All of an item's types share one backing rep.
                let representation = content.representations[item.types[0].representationIndex]
                var types: [NSPasteboard.PasteboardType] = []
                // The planner emits the content (image) UTI before `.fileURL` iff
                // the rep inlines.
                let imageType = item.types.first { !$0.isFileURL }
                    .map { NSPasteboard.PasteboardType($0.uti) }
                if let imageType { types.append(imageType) }

                // The image flavor must read the SAME staged file: reading
                // `representation.fileURL` lazily could vend empty bytes once a
                // transient source is swept.
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
                            // Staging produced no durable file.
                            return inlineData(for: representation)
                        }
                        return nil
                    })
            } else {
                var inlineByType: [NSPasteboard.PasteboardType: ClipboardContent.Representation] = [:]
                var inlineTypes: [NSPasteboard.PasteboardType] = []
                for promised in item.types {
                    let type = NSPasteboard.PasteboardType(promised.uti)
                    inlineByType[type] = content.representations[promised.representationIndex]
                    inlineTypes.append(type)
                }
                // Snapshot to a `let` so the @Sendable closure captures an
                // immutable map.
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
    /// The caller gates this to image payloads (`shouldInlineOnPasteboard`), so
    /// there is no size ceiling to apply (CLIPBOARD.md §1).
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
    /// An inline-and-named payload (image file) is written to a fresh sink so its
    /// `.fileURL` outlives the VM teardown.
    nonisolated private static func stagedFileURL(
        for representation: ClipboardContent.Representation, generation: UInt64,
        staging: ClipboardFileStaging
    ) -> URL? {
        if let existing = representation.fileURL {
            // Already on disk — a pulled file rep, a folder whose tree its
            // transfer extracted, or a rare spilled inline payload.
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
enum HostPublishOutcome {
    /// No representation could be served — every file payload was dropped and
    /// there was no inline/lazy content. `reasons` is most-actionable first.
    case nothingServed(reasons: [CopyToMacDropReason])
    /// Reps resolved, but building their pasteboard items produced none (e.g. a
    /// lone directory whose archive couldn't be extracted).
    case stagingFailed
    /// The write succeeded. `droppedReasons` lists payloads that couldn't be
    /// served alongside the placed items; `changeCount` is the write pasteboard's
    /// change count right after the write.
    case written(
        representationCount: Int, droppedReasons: [CopyToMacDropReason], changeCount: Int)
    /// `writeObjects` returned false — nothing was placed.
    case writeFailed

    /// The pasteboard's change count right after a successful write, else `nil`.
    var postWriteChangeCount: Int? {
        if case .written(_, _, let changeCount) = self { return changeCount }
        return nil
    }

    /// Payloads this publish could not serve, whether or not anything else was.
    var droppedReasons: [CopyToMacDropReason] {
        switch self {
        case .nothingServed(let reasons): return reasons
        case .written(_, let droppedReasons, _): return droppedReasons
        case .stagingFailed, .writeFailed: return []
        }
    }
}
