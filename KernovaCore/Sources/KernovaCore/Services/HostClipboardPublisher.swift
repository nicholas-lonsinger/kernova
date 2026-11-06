import Foundation
import KernovaKit
import KernovaLogging
import KernovaWire

/// Writes a VM's clipboard to the host pasteboard: passthrough's write of the
/// guest's clipboard, lazily, and a copy command's of it, as data with its files
/// promised.
///
/// Each item promises its types through a `LazyClipboardDataProvider`, handed to
/// the app-scoped provider registry on a successful write — a paste can land
/// long after the VM is gone.
@MainActor
package final class HostClipboardPublisher {
    /// Label for the host-side clipboard staging root.
    ///
    /// Never swept on window/VM teardown — that would invalidate a just-copied
    /// file URL still on the pasteboard — so it goes with its process root, once
    /// the process has exited.
    static let stagingLabel = "host"

    /// The pasteboard every publication lands on, which a passthrough
    /// coordinator polls through this publisher so both name the same one.
    package let pasteboard: any ClipboardPasteboard

    /// The shared write choke point every publication goes through.
    private let publisher: ClipboardPasteboardPublisher

    /// Materializes inline/directory payloads to local temp files so a Finder
    /// paste creates real files.
    ///
    /// Recent generations are retained so a just-copied URL on the pasteboard
    /// stays valid across a couple more copies.
    private let staging: ClipboardFileStaging

    /// Monotonic generation for the staging root, bumped per publish
    /// so each supersedes older staged artifacts within the recency window.
    private var stagingGeneration: UInt64 = 1

    /// Hears each paste of a write of this publisher's whose promised bytes the pasteboard refused.
    var onPasteRefused: (@MainActor () -> Void)? {
        get { publisher.onPasteRefused }
        set { publisher.onPasteRefused = newValue }
    }

    /// The change a passthrough coordinator polling the same pasteboard skips,
    /// so guest content is never re-forwarded back to the guest.
    var lastWriteChangeCount: Int? { publisher.lastWriteChangeCount }

    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "HostClipboardPublisher")

    #if DEBUG
    /// Awaited between the staging hop and the cancellation check that guards the
    /// write, so a test can park a publish in that gap and land a cancellation
    /// there deterministically — the window a caller's cancellation has to hit
    /// for the write to be stopped, and the one no gate before the first await
    /// can reach.
    var beforePasteboardWriteForTesting: (@MainActor () async -> Void)?
    #endif

    /// Publishes to `pasteboard`, the host's general pasteboard in
    /// production, and stages under `stagingRoot`,
    /// `ClipboardFileStaging.processRoot` in production.
    init(
        pasteboard: any ClipboardPasteboard,
        providerRegistry: LazyClipboardProviderRegistry = .shared,
        stagingRoot: ProcessStagingRoot
    ) {
        self.pasteboard = pasteboard
        self.publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: providerRegistry)
        self.staging = ClipboardFileStaging(
            label: HostClipboardPublisher.stagingLabel, root: stagingRoot)
    }

    /// Builds the service's guest clipboard items and writes them to the host
    /// pasteboard as lazy promised items, returning the terminal outcome.
    ///
    /// A live guest offer publishes from metadata alone — every promised type's
    /// bytes are pulled at paste time through the offer's puller — so nothing
    /// crosses the wire here; resolved (local) reps stage their bytes.
    ///
    /// Cooperatively cancellable: a task cancelled before the write throws
    /// `CancellationError` with the pasteboard untouched and its staging
    /// discarded, so a publish the caller no longer wants never lands.
    package func publish(from service: any ClipboardServicing) async throws(CancellationError)
        -> HostPublishOutcome
    {
        guard !Task.isCancelled else { throw CancellationError() }
        let staging = self.staging
        let generation = stagingGeneration
        stagingGeneration += 1

        let copyItems = service.guestClipboardItems()
        var resolvedReps: [ClipboardContent.Representation] = []
        var offers: [CopyToMacOffer] = []
        var droppedReasons: [CopyToMacDropReason] = []
        for item in copyItems {
            switch item {
            case .resolved(let rep): resolvedReps.append(rep)
            case .offer(let offer): offers.append(offer)
            case .droppedFile(let reason): droppedReasons.append(reason)
            }
        }
        guard !resolvedReps.isEmpty || !offers.isEmpty else {
            return .nothingServed(reasons: droppedReasons)
        }

        var specs: [ClipboardPasteboardPublisher.ItemSpec]
        do throws(CancellationError) {
            specs = try await Self.hostPasteboardItems(
                for: ClipboardContent(representations: resolvedReps), generation: generation,
                staging: staging)
            #if DEBUG
            await beforePasteboardWriteForTesting?()
            #endif
            // The stage is where the task was off the actor; a cancellation that
            // arrived meanwhile must stop the write, the one observable step.
            guard !Task.isCancelled else { throw CancellationError() }
        } catch {
            // Nothing was written, so nothing can be serving from this generation.
            staging.discardGeneration(generation)
            throw error
        }
        for offer in offers {
            specs += ClipboardPasteboardPublisher.itemSpecs(
                for: offer.items, concealed: offer.concealed, servingFileURLs: offer.servingFileURLs,
                puller: offer.puller)
        }

        // An empty `specs` means every resolved payload was dropped (e.g. a lone
        // folder that failed to extract). Surface that rather than clearing the
        // Mac clipboard to write nothing.
        guard !specs.isEmpty else {
            Self.logger.log(.error, "Host clipboard publish produced no pasteboard items (staging failed)")
            return .stagingFailed
        }

        var parts = offers.map {
            ClipboardWriteSource.Part(
                items: $0.items, concealed: $0.concealed, servingFileURLs: $0.servingFileURLs, puller: $0.puller)
        }
        if !resolvedReps.isEmpty { parts.insert(.init(holding: resolvedReps), at: 0) }
        guard publisher.write(specs, source: ClipboardWriteSource(serving: offers.first?.serving, parts: parts))
        else {
            Self.logger.log(.error, "The pasteboard write failed for a host clipboard publish")
            return .writeFailed
        }
        let representationCount =
            resolvedReps.count + offers.reduce(0) { $0 + $1.items.reduce(0) { $0 + $1.representations.count } }
        Self.logger.log(
            .info,
            "Published the guest's clipboard to the host pasteboard (\(representationCount, privacy: .public) reps, \(specs.count, privacy: .public) items, \(droppedReasons.count, privacy: .public) dropped)"
        )
        return .written(representationCount: representationCount, droppedReasons: droppedReasons)
    }

    /// Writes the guest's copy `contents`: every representation but a file or folder as data, the files
    /// promised, and withheld when `servingFileURLs` is false. The copy is released once something replaces its
    /// write, or at once when the write failed or does not hold it: it promised no file, and is not concealed.
    /// Returns whether the write was taken.
    func writeCopy(_ contents: GuestCopyContents, servingFileURLs: Bool) -> Bool {
        let (written, holdsCopy) = publisher.publishCopy(
            contents.items, concealed: contents.concealed, servingFileURLs: servingFileURLs,
            held: contents.held, puller: contents.puller, serving: contents.serving,
            onReleased: contents.release)
        if !written || !holdsCopy { contents.release() }
        Self.logger.log(
            .info,
            "Wrote the guest's clipboard copy to the host pasteboard (written: \(written, privacy: .public), held until replaced: \(holdsCopy, privacy: .public))"
        )
        return written
    }

    /// `true` while the host pasteboard still holds this publisher's most recent
    /// write — nothing (the user included) has replaced it since.
    var pasteboardHoldsLastWrite: Bool { publisher.holdsLastWrite }

    /// Withdraws `withdrawal`'s promises of this publisher's most recent write
    /// when the host pasteboard still holds it and it serves the offer
    /// `token`, and returns what that left: what the offer's end owes a write
    /// whose promises it can no longer serve
    /// (``ClipboardPasteboardPublisher/retractWrite(servingOffer:withdrawing:)``).
    func retractWrite(servingOffer token: Data, withdrawing withdrawal: ClipboardWithdrawal) -> ClipboardRetraction? {
        publisher.retractWrite(servingOffer: token, withdrawing: withdrawal)
    }

    /// Builds the per-item provider specs to promise on the host pasteboard for
    /// the eagerly-resolved `content`, deferring inline byte reads to paste time.
    ///
    /// A single inline item promises every inline (filename-less) representation;
    /// each file payload becomes its own item promising exactly one `.fileURL`
    /// (and, for an image file, its inline image bytes too). One `.fileURL` per
    /// item is what a Finder paste needs to create N files — an item holds only
    /// one value per type, so several file URLs in one item would collide.
    ///
    /// Checks for cancellation before each item's stage, so a cancelled publish
    /// of many files unwinds at the next file rather than staging them all.
    nonisolated static func hostPasteboardItems(
        for content: ClipboardContent, generation: UInt64, staging: ClipboardFileStaging
    ) async throws(CancellationError) -> [ClipboardPasteboardPublisher.ItemSpec] {
        let descriptors = content.representations.map {
            ClipboardRepresentationDescriptor(
                uti: $0.uti, filename: $0.filename,
                isInline: $0.shouldInlineOnPasteboard, isPromisable: true)
        }
        let plan = ClipboardPasteboardItemPlan.plan(for: descriptors)

        var specs: [ClipboardPasteboardPublisher.ItemSpec] = []
        for item in plan.items {
            guard !Task.isCancelled else { throw CancellationError() }
            if item.types.contains(where: \.isFileURL) {
                // All of an item's types share one backing rep.
                let representation = content.representations[item.types[0].representationIndex]
                var types: [String] = []
                // The planner emits the content (image) UTI before `.fileURL` iff
                // the rep inlines.
                let imageType = item.types.first { !$0.isFileURL }?.uti
                if let imageType { types.append(imageType) }

                // The image flavor must read the SAME staged file: reading
                // `representation.fileURL` lazily could vend empty bytes once a
                // transient source is swept.
                let stagedURL = stagedFileURL(
                    for: representation, generation: generation, staging: staging)
                let fileURLData = stagedURL.map { Data($0.absoluteString.utf8) }
                let fileURLType = ClipboardPasteboardPublisher.ItemSpec.fileURLType
                if fileURLData != nil { types.append(fileURLType) }

                guard !types.isEmpty else { continue }
                specs.append(
                    ClipboardPasteboardPublisher.ItemSpec(types: types) { type in
                        if type == fileURLType { return fileURLData }
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
                var inlineByType: [String: ClipboardContent.Representation] = [:]
                var inlineTypes: [String] = []
                for promised in item.types {
                    inlineByType[promised.uti] = content.representations[promised.representationIndex]
                    inlineTypes.append(promised.uti)
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
    /// there is no size ceiling to apply — docs/CLIPBOARD.md, "No Kernova-imposed
    /// size bound".
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
package enum HostPublishOutcome {
    /// No representation could be served — every file payload was dropped and
    /// there was no inline/lazy content. `reasons` is most-actionable first.
    case nothingServed(reasons: [CopyToMacDropReason])
    /// Reps resolved, but building their pasteboard items produced none (e.g. a
    /// lone directory whose archive couldn't be extracted).
    case stagingFailed
    /// The write succeeded. `droppedReasons` lists payloads that couldn't be
    /// served alongside the placed items.
    case written(representationCount: Int, droppedReasons: [CopyToMacDropReason])
    /// `writeObjects` returned false — nothing was placed.
    case writeFailed

    /// Payloads this publish could not serve, whether or not anything else was.
    var droppedReasons: [CopyToMacDropReason] {
        switch self {
        case .nothingServed(let reasons): return reasons
        case .written(_, let droppedReasons): return droppedReasons
        case .stagingFailed, .writeFailed: return []
        }
    }
}
