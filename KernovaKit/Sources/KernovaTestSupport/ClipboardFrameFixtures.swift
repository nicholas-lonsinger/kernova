import CryptoKit
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
/// For the payloads the streaming engine builds inside itself, which have no
/// `Frame` factory to call; every control frame below goes through the
/// production builder instead, so a fixture can never describe a frame the
/// shipping one would not.
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

/// A `ClipboardRequest` pulling one representation of a generation.
public func makeRequestFrame(
    generation: UInt64, transferID: UInt64, uti: String, maxAcceptByteCount: UInt64 = .max
) -> Frame {
    .clipboardRequest(
        generation: generation, transferID: transferID, uti: uti,
        maxAcceptByteCount: maxAcceptByteCount)
}

/// A `ClipboardStreamBegin` opening an inbound transfer.
///
/// `isArchive` says the chunks that follow are an LZ4 AppleArchive the receiver
/// extracts as they arrive, in which case `totalBytes` is the wire size — which
/// the real sender never knows at Begin, so it declares 0.
public func makeBeginFrame(
    generation: UInt64, transferID: UInt64, uti: String, totalBytes: Int, filename: String = "",
    isInline: Bool, isArchive: Bool = false
) -> Frame {
    var begin = Kernova_V1_ClipboardStreamBegin()
    begin.generation = generation
    begin.transferID = transferID
    begin.uti = uti
    begin.totalBytes = UInt64(totalBytes)
    begin.filename = filename
    begin.isInline = isInline
    begin.isArchive = isArchive
    var frame = versionedFrame()
    frame.clipboardStreamBegin = begin
    return frame
}

/// A `ClipboardChunk` carrying `data` at `offset` for a transfer.
public func makeChunkFrame(transferID: UInt64, offset: Int, data: Data) -> Frame {
    var chunk = Kernova_V1_ClipboardChunk()
    chunk.transferID = transferID
    chunk.offset = UInt64(offset)
    chunk.data = data
    var frame = versionedFrame()
    frame.clipboardChunk = chunk
    return frame
}

/// A `ClipboardStreamEnd` closing a transfer, with the real SHA-256 over
/// `payload` so a receiver verifies and commits.
public func makeEndFrame(transferID: UInt64, payload: Data) -> Frame {
    var end = Kernova_V1_ClipboardStreamEnd()
    end.transferID = transferID
    end.totalBytes = UInt64(payload.count)
    end.sha256 = Data(SHA256.hash(data: payload))
    var frame = versionedFrame()
    frame.clipboardStreamEnd = end
    return frame
}

/// A `ClipboardStreamAbort` failing a transfer.
///
/// `code` is the bare wire string rather than a `ClipboardStreamAbortCode` so a
/// test can inject one this build does not define; pass
/// `ClipboardStreamAbortCode.<case>.rawValue` when the code is meant to be read.
public func makeAbortFrame(transferID: UInt64, code: String, message: String) -> Frame {
    var abort = Kernova_V1_ClipboardStreamAbort()
    abort.transferID = transferID
    abort.code = code
    abort.message = message
    var frame = versionedFrame()
    frame.clipboardStreamAbort = abort
    return frame
}

/// A `ClipboardStreamAck` releasing/crediting an outbound transfer.
///
/// `windowBytes` defaults to a generous window so a whole payload can flow
/// without further acks; `bytesConsumed` is cumulative.
public func makeAckFrame(
    transferID: UInt64, bytesConsumed: Int = 0, windowBytes: Int = 512 * 1024
) -> Frame {
    var ack = Kernova_V1_ClipboardStreamAck()
    ack.transferID = transferID
    ack.bytesConsumed = UInt64(bytesConsumed)
    ack.windowBytes = UInt64(windowBytes)
    var frame = versionedFrame()
    frame.clipboardStreamAck = ack
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
