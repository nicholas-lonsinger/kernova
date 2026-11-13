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
    /// The pasteboard every publication lands on, which a passthrough
    /// coordinator polls through this publisher so both name the same one.
    package let pasteboard: any ClipboardPasteboard

    /// The shared write choke point every publication goes through.
    private let publisher: ClipboardPasteboardPublisher

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

    /// Publishes to `pasteboard`, the host's general pasteboard in production.
    init(pasteboard: any ClipboardPasteboard, providerRegistry: LazyClipboardProviderRegistry = .shared) {
        self.pasteboard = pasteboard
        self.publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: providerRegistry)
    }

    /// Writes the service's guest clipboard items to the host pasteboard as lazy promised items, returning the
    /// terminal outcome.
    ///
    /// A live guest offer publishes from metadata alone — every promised type's bytes are pulled at paste time
    /// through the offer's puller — so nothing crosses the wire here.
    package func publish(from service: any ClipboardServicing) -> HostPublishOutcome {
        var offers: [CopyToMacOffer] = []
        var droppedReasons: [CopyToMacDropReason] = []
        for item in service.guestClipboardItems() {
            switch item {
            case .offer(let offer): offers.append(offer)
            case .droppedFile(let reason): droppedReasons.append(reason)
            }
        }
        let specs = offers.flatMap {
            ClipboardPasteboardPublisher.itemSpecs(
                for: $0.items, concealed: $0.concealed, servingFileURLs: $0.servingFileURLs, puller: $0.puller)
        }
        guard !specs.isEmpty else { return .nothingServed(reasons: droppedReasons) }

        let parts = offers.map {
            ClipboardWriteSource.Part(
                items: $0.items, concealed: $0.concealed, servingFileURLs: $0.servingFileURLs, puller: $0.puller)
        }
        guard publisher.write(specs, source: ClipboardWriteSource(serving: offers.first?.serving, parts: parts))
        else {
            Self.logger.log(.error, "The pasteboard write failed for a host clipboard publish")
            return .writeFailed
        }
        let representationCount = offers.reduce(0) { $0 + $1.items.reduce(0) { $0 + $1.representations.count } }
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
}

/// The terminal state of a `HostClipboardPublisher.publish(from:)`.
package enum HostPublishOutcome {
    /// Nothing could be served — every file payload was dropped and no offer
    /// promised anything. `reasons` is most-actionable first.
    case nothingServed(reasons: [CopyToMacDropReason])
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
        case .writeFailed: return []
        }
    }
}
