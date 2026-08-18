import Foundation
import KernovaKit

/// One representation's metadata as it rides in an offer's `repInfo`.
///
/// Mirrors `Kernova_V1_ClipboardRepresentationInfo` so a test can describe an
/// offer declaratively.
public struct RepInfo: Sendable {
    /// Uniform Type Identifier naming the representation's format.
    public var uti: String
    /// Declared size — the figure the paste budget and the receiver's ceilings
    /// are measured against, which a test may set past any real payload.
    public var byteCount: UInt64
    /// Suggested filename; empty for inline-only content.
    public var filename: String
    /// Whether the representation inlines onto the pasteboard.
    public var isInline: Bool
    /// Whether the payload is a folder, carried as an archive of its tree.
    public var isDirectory: Bool

    /// Describes one offered representation.
    public init(
        uti: String, byteCount: UInt64, filename: String = "", isInline: Bool,
        isDirectory: Bool = false
    ) {
        self.uti = uti
        self.byteCount = byteCount
        self.filename = filename
        self.isInline = isInline
        self.isDirectory = isDirectory
    }

    /// A single inline text representation (`public.utf8-plain-text`).
    public static func text(_ string: String) -> RepInfo {
        RepInfo(
            uti: ClipboardContent.utf8TextUTI, byteCount: UInt64(Data(string.utf8).count),
            isInline: true)
    }

    /// The wire message this describes.
    public var wire: Kernova_V1_ClipboardRepresentationInfo {
        var info = Kernova_V1_ClipboardRepresentationInfo()
        info.uti = uti
        info.byteCount = byteCount
        info.filename = filename
        info.isInline = isInline
        info.isDirectory = isDirectory
        return info
    }
}

/// A frame with the protocol version every consumer requires.
///
/// For the data connection's own header frames, which have no `Frame` factory
/// to call; every control frame below goes through the production builder
/// instead, so a fixture can never describe a frame the shipping one would not.
private func versionedFrame() -> Frame {
    var frame = Frame()
    frame.protocolVersion = 1
    return frame
}

/// A metadata-only `ClipboardOffer` carrying one `repInfo` entry per
/// representation — no bytes ride in an offer.
public func makeOfferFrame(
    generation: UInt64, reps: [RepInfo], isConcealed: Bool = false
) -> Frame {
    .clipboardOffer(generation: generation, reps: reps.map(\.wire), isConcealed: isConcealed)
}

/// An offer for a single inline text representation.
public func makeTextOfferFrame(generation: UInt64, text: String) -> Frame {
    makeOfferFrame(generation: generation, reps: [.text(text)])
}

/// A `ClipboardRelease` withdrawing an offer.
public func makeReleaseFrame(generation: UInt64) -> Frame {
    .clipboardRelease(generation: generation)
}

/// A `DropOffer` announcing one drop's items.
public func makeDropOfferFrame(generation: UInt64, reps: [RepInfo]) -> Frame {
    .dropOffer(generation: generation, reps: reps.map(\.wire))
}

/// A `DropRelease` calling off one drop.
public func makeDropReleaseFrame(generation: UInt64) -> Frame {
    .dropRelease(generation: generation)
}

/// A `ClipboardRequest` asking the peer to dial one representation's data
/// connection.
public func makeRequestFrame(
    generation: UInt64, transferID: UInt64, uti: String, maxAcceptByteCount: UInt64 = .max
) -> Frame {
    .clipboardRequest(
        generation: generation, transferID: transferID, uti: uti,
        maxAcceptByteCount: maxAcceptByteCount)
}

/// A `ClipboardTransferRequest` — the frame a dialling receiver opens its data
/// connection with, which is the pull itself in that direction.
public func makeTransferRequestFrame(
    generation: UInt64, transferID: UInt64, uti: String, maxAcceptByteCount: UInt64 = .max
) -> Frame {
    var frame = versionedFrame()
    frame.clipboardTransferRequest = Kernova_V1_ClipboardTransferRequest.with {
        $0.generation = generation
        $0.transferID = transferID
        $0.uti = uti
        $0.maxAcceptByteCount = maxAcceptByteCount
    }
    return frame
}

/// A `ClipboardTransferReply` describing the payload that follows it on the
/// connection.
///
/// `isArchive` says those bytes are an LZ4 AppleArchive the receiver extracts as
/// they arrive, in which case the real sender declares `totalBytes` 0 — a
/// compressed size it cannot know before producing it.
public func makeTransferReplyFrame(
    transferID: UInt64, isArchive: Bool, isInline: Bool, totalBytes: Int
) -> Frame {
    var frame = versionedFrame()
    frame.clipboardTransferReply = Kernova_V1_ClipboardTransferReply.with {
        $0.transferID = transferID
        $0.isArchive = isArchive
        $0.isInline = isInline
        $0.totalBytes = UInt64(max(0, totalBytes))
    }
    return frame
}

/// A `ClipboardTransferReply` refusing a transfer outright: no payload and no
/// trailer follow it.
///
/// `code` is the bare wire string rather than a `ClipboardStreamAbortCode` so a
/// test can inject one this build does not define; pass
/// `ClipboardStreamAbortCode.<case>.rawValue` when the code is meant to be read.
public func makeTransferRefusalFrame(
    transferID: UInt64, code: String, message: String
) -> Frame {
    var frame = versionedFrame()
    frame.clipboardTransferReply = Kernova_V1_ClipboardTransferReply.with {
        $0.transferID = transferID
        $0.refusalCode = code
        $0.refusalMessage = message
    }
    return frame
}

/// An `Error` frame reporting a refusal the peer raised.
public func makeErrorFrame(code: String, message: String, inReplyTo: String? = nil) -> Frame {
    var error = Kernova_V1_Error()
    error.code = code
    error.message = message
    if let inReplyTo { error.inReplyTo = inReplyTo }
    var frame = versionedFrame()
    frame.error = error
    return frame
}

/// A `DropComplete` reporting how a drop ended.
public func makeDropCompleteFrame(
    generation: UInt64, outcome: Kernova_V1_DropComplete.Outcome,
    code: ClipboardErrorCode? = nil, message: String = ""
) -> Frame {
    .dropComplete(generation: generation, outcome: outcome, code: code, message: message)
}
