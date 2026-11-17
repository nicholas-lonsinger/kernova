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

    /// Writes the service's live guest offer to the host pasteboard as lazy promised items within its paste
    /// ceiling, returning what became of the pasteboard; nothing to write when there is no live offer.
    ///
    /// The write is metadata alone — every promised type's bytes are pulled at paste time through the offer's
    /// puller — so nothing crosses the wire here.
    package func publish(from service: any ClipboardServicing) -> ClipboardOfferPublishOutcome {
        guard let offer = service.guestClipboardOffer() else { return .nothingToWrite }
        return publisher.publish(
            offer.items, concealed: offer.concealed, pasteCeiling: offer.limitBytes, puller: offer.puller,
            serving: offer.serving)
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

    /// Withdraws `withdrawal`'s promises of this publisher's most recent write
    /// when the host pasteboard still holds it and it serves the offer
    /// `token`, and returns what that left: what the offer's end owes a write
    /// whose promises it can no longer serve
    /// (``ClipboardPasteboardPublisher/retractWrite(servingOffer:withdrawing:)``).
    func retractWrite(servingOffer token: Data, withdrawing withdrawal: ClipboardWithdrawal) -> ClipboardRetraction? {
        publisher.retractWrite(servingOffer: token, withdrawing: withdrawal)
    }
}
