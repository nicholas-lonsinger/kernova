import Foundation
import KernovaKit
import KernovaWire

/// Common surface shared by every clipboard transport.
///
/// `SpiceClipboardService` carries only UTF-8 text; `HubClipboardService`, over the guest agent's items, carries
/// every representation. Both implementations must be `@Observable` classes: the macro installs the registrar
/// on the concrete type, so reading through the protocol witness still fires observation.
@MainActor
package protocol ClipboardServicing: AnyObject {
    /// `true` once the implementation has completed its handshake with the guest.
    var isConnected: Bool { get }

    /// `true` when the transport carries arbitrary UTI-tagged representations;
    /// `false` when it is limited to plain text (SPICE).
    var supportsBinaryRepresentations: Bool { get }

    /// Bumped once per new guest clipboard the transport takes, which passthrough writes to the Mac.
    var inboundOfferSeq: UInt64 { get }

    /// Stops protocol I/O. Idempotent.
    func stop()

    /// Offers a copy on the Mac to the guest, as passthrough read it from the host pasteboard: metadata only,
    /// each representation's bytes read from `copy` when this transport sends them.
    ///
    /// `.settled` means this copy is done with — announced, already held by the guest, or carrying nothing this
    /// transport can send. `.undelivered` means nothing reached the guest and offering the same copy again on a
    /// live connection would send it.
    func offerHostCopy(_ copy: ClipboardOfferSource) async -> ClipboardGrabOutcome

    /// The Mac's pasteboard changed to a copy passthrough offers nothing of — empty, transient, or none of it
    /// readable: the host's offer of the copy before it is withdrawn. Default: nothing to withdraw.
    func hostCopyOffersNothing()

    /// Whether the transport resolves offers that cross, the host's winning: passthrough then offers each new
    /// connection the Mac's copy as it stands, and turning it on leaves both sides the newer copy. A transport
    /// that does not would swap two clipboards that crossed, so it is offered only copies made while connected.
    var resolvesCrossings: Bool { get }

    /// Bumped once per connection to the guest, so passthrough tells a new connection from the last however
    /// fast one replaced the other. Default 0: a transport whose service is per connection.
    var connectionEpoch: UInt64 { get }

    /// The host pasteboard's change count when this clipboard last changed, so turning passthrough on can tell
    /// whether the Mac's copy or the guest's is newer; nil when the transport keeps no record.
    var clipboardChangeMark: Int? { get }

    /// Whether the guest's offer is this clipboard's now, for passthrough to publish.
    var hasStandingGuestOffer: Bool { get }

    /// The host pasteboard's change count when the last connection to the guest ended, after what its end
    /// retracted; nil before any ended, or when the transport keeps no record. A Mac copy made since it is one
    /// the guest has not seen.
    var changeCountAtLinkLoss: Int? { get }

    /// Copies `snapshot`, the Mac's clipboard as it stood at the command, to the guest's: what does not reach it
    /// at once, or nil. A refusal the guest answers later goes to the VM's transfer report.
    func copyMacClipboardToGuest(_ snapshot: ClipboardOfferSource) -> ClipboardTransferFailure?

    /// The guest's clipboard as it stands now, every representation but a file or folder already landed here.
    func guestClipboardCopy() async -> GuestClipboardCopy

    /// The token of the guest's offer that is this clipboard's now, which a host-pasteboard write of it serves;
    /// nil when there is none, or the transport names none.
    var guestOfferToken: Data? { get }

    /// Reserves a directory to call a file promise copied on the Mac in to when the guest pulls it, or `nil`
    /// when the transport can't stage one. Default `nil`: a text-only transport never takes a file.
    func reservePromiseDestination() -> URL?

    /// The guest's clipboard as passthrough places it on the host pasteboard — metadata only, synchronously.
    ///
    /// A live guest offer becomes one `.offer` whose bytes are pulled when a paste consumes them; text the
    /// transport already holds returns `.resolved`. Files that can never be served are reported as
    /// `.droppedFile`.
    func guestClipboardItems() -> [CopyToMacItem]
}

/// The guest's clipboard, as a copy command took it.
package enum GuestClipboardCopy {
    /// It held nothing to copy.
    case nothing
    /// It held its write of the host's own offer, which the Mac's clipboard holds already.
    case alreadyHeld
    /// It could not be copied, and why.
    case failed(ClipboardTransferFailure)
    /// The copy, to be written to the Mac.
    case copy(GuestCopyContents)
}

/// A copy of the guest's clipboard: its items, every non-file representation landed, and the files still on
/// the guest's disk, pulled when pasted.
package struct GuestCopyContents {
    /// The copy's token, which a retraction of its write names.
    let token: Data
    let items: [OfferedItem]
    let concealed: Bool
    /// How the copy is written within the paste ceiling, decided once its INLINE representations landed.
    let plan: ClipboardPromisePolicy.CopyPlan
    /// The bytes INLINE representation `rep` of item `item` landed with.
    let landed: @Sendable (_ item: Int, _ rep: Int) -> Data?
    /// Pulls the copy's files when a paste asks.
    let puller: any ClipboardItemPulling
    /// Lets the copy go, the Mac's clipboard holding nothing more of it.
    let release: @MainActor () -> Void
}

/// What became of an `offerHostCopy(_:)`.
///
/// Splits the one outcome a caller can act on — nothing reached the guest, and the same copy offered again on
/// a live connection would go out — from every outcome that is final for this copy.
package enum ClipboardGrabOutcome: Equatable, Sendable {
    case settled
    case undelivered
}

/// A guest's live offer as passthrough places it on the host pasteboard: every item promised, its bytes pulled
/// through `puller` only when a paste asks for them.
package struct CopyToMacOffer: Sendable {
    /// The offer's token, which a retraction of its write names.
    let token: Data
    let items: [OfferedItem]
    let concealed: Bool
    /// `false` leaves `public.file-url` off every item — the over-cap refusal,
    /// whose inline flavors keep serving.
    let servingFileURLs: Bool
    let puller: any ClipboardItemPulling
}

/// One item passthrough places on the host pasteboard.
package enum CopyToMacItem: Sendable {
    /// A representation whose bytes are already local — the text a text-only transport received.
    case resolved(ClipboardContent.Representation)
    /// A guest offer, promised whole; its bytes cross the wire only when a
    /// paste consumes them.
    case offer(CopyToMacOffer)
    /// A file payload that can't be served — the `reason` drives the
    /// user-facing message.
    case droppedFile(CopyToMacDropReason)
}

/// Why a file payload couldn't be placed on the host pasteboard.
package enum CopyToMacDropReason: Sendable, Equatable {
    /// The offer's `public.file-url`-serving reps total over the user's paste
    /// ceiling (`ClipboardPasteLimit`), so no paste could pull them inside the OS
    /// pasteboard-promise deadline. All-or-nothing: the whole set is refused
    /// together rather than landing piecemeal.
    case overPasteBudget
}

extension ClipboardServicing {
    func reservePromiseDestination() -> URL? { nil }
    func hostCopyOffersNothing() {}
    var resolvesCrossings: Bool { false }
    var connectionEpoch: UInt64 { 0 }
    var clipboardChangeMark: Int? { nil }
    var hasStandingGuestOffer: Bool { false }
    var changeCountAtLinkLoss: Int? { nil }
    var guestOfferToken: Data? { nil }
}
