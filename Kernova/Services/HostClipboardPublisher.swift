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

    /// The shared write choke point every publication goes through.
    private let publisher: ClipboardPasteboardPublisher

    /// Materializes inline/directory payloads to local temp files so a Finder
    /// paste creates real files.
    ///
    /// Recent generations are retained so a just-copied URL on the pasteboard
    /// stays valid across a couple more copies.
    private let staging = ClipboardFileStaging(label: HostClipboardPublisher.stagingLabel)

    /// Monotonic generation for the launch-swept staging root, bumped per publish
    /// so each supersedes older staged artifacts within the recency window.
    private var stagingGeneration: UInt64 = 1

    /// The change a passthrough coordinator polling the same pasteboard skips,
    /// so guest content is never re-forwarded back to the guest.
    var lastWriteChangeCount: Int? { publisher.lastWriteChangeCount }

    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "HostClipboardPublisher")

    init(
        writePasteboard: any ClipboardWritePasteboard = NSPasteboard.general,
        providerRegistry: LazyClipboardProviderRegistry = .shared
    ) {
        self.publisher = ClipboardPasteboardPublisher(
            pasteboard: writePasteboard, providerRegistry: providerRegistry)
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
        if let serving = service as? any ClipboardPromiseServing {
            specs += Self.promisedItemSpecs(for: promises, serve: serving)
        }

        // An empty `specs` means every resolved payload was dropped (e.g. a lone
        // folder that failed to extract). Surface that rather than clearing the
        // Mac clipboard to write nothing.
        guard !specs.isEmpty else {
            Self.logger.error("Host clipboard publish produced no pasteboard items (staging failed)")
            return .stagingFailed
        }

        guard publisher.write(specs, promised: !promises.isEmpty),
            let changeCount = publisher.lastWriteChangeCount
        else {
            Self.logger.error("The pasteboard write failed for a host clipboard publish")
            return .writeFailed
        }
        let representationCount = resolvedReps.count + promises.count
        Self.logger.info(
            "Published clipboard buffer to host pasteboard (\(representationCount, privacy: .public) reps, \(specs.count, privacy: .public) items, \(droppedReasons.count, privacy: .public) dropped)"
        )
        return .written(
            representationCount: representationCount, droppedReasons: droppedReasons,
            changeCount: changeCount)
    }

    /// `true` while the host pasteboard still holds this publisher's most recent
    /// write — nothing (the user included) has replaced it since.
    var pasteboardHoldsLastWrite: Bool { publisher.holdsLastWrite }

    /// Clears the host pasteboard when it still holds this publisher's most
    /// recent *promised* write, returning whether it did — the stale-promise
    /// retraction the clipboard service triggers when the guest's clipboard
    /// supersedes an offer whose promises can no longer be served.
    func retractPromisedWrite() -> Bool {
        guard publisher.retractPromisedWrite() else { return false }
        Self.logger.notice("Retracted stale promised clipboard write from the host pasteboard")
        return true
    }

    /// Builds the per-item provider specs for reps promised by offer coordinates —
    /// the same grouping the resolved path plans, driven by offer metadata alone.
    ///
    /// The pull each flavor's closure runs happens on the thread of the
    /// pasteboard server's `provideData` callback (usually main, which keeps
    /// running its event loop meanwhile) while the stream receiver delivers
    /// off-main; the offer's paste-bound total is size-capped so the pull and
    /// stage complete within the OS paste deadline. A promise that withholds
    /// `.fileURL` (the over-cap refusal) never registers that type.
    nonisolated static func promisedItemSpecs(
        for promises: [CopyToMacPromise], serve: any ClipboardPromiseServing
    ) -> [ClipboardPasteboardPublisher.ItemSpec] {
        let descriptors = promises.map {
            ClipboardRepresentationDescriptor(
                uti: $0.uti, filename: $0.filename, isInline: $0.isInline, isPromisable: true)
        }
        // A "Copy to Mac" plans over the promises it kept, not the offer's own
        // representations, so a promised type's index is into `promises` and the
        // coordinates it serves from come from there.
        return ClipboardPasteboardPublisher.specs(
            for: ClipboardPasteboardItemPlan.plan(for: descriptors), serve: serve
        ) { promisedType in
            let promise = promises[promisedType.representationIndex]
            guard !(promisedType.isFileURL && promise.withholdsFileURL) else { return nil }
            return (generation: promise.generation, repIndex: promise.repIndex)
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
    ) async -> [ClipboardPasteboardPublisher.ItemSpec] {
        let descriptors = content.representations.map {
            ClipboardRepresentationDescriptor(
                uti: $0.uti, filename: $0.filename,
                isInline: $0.shouldInlineOnPasteboard, isPromisable: true)
        }
        let plan = ClipboardPasteboardItemPlan.plan(for: descriptors)

        var specs: [ClipboardPasteboardPublisher.ItemSpec] = []
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
                    ClipboardPasteboardPublisher.ItemSpec(types: types) { type in
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
                    ClipboardPasteboardPublisher.ItemSpec(types: inlineTypes) { type in
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
