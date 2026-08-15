import Foundation

/// Stable machine-readable reasons a `ClipboardStreamAbort` gives for ending a
/// transfer, named `<stage>.<condition>`.
///
/// The raw value is what the frame carries and what the receiving side matches
/// on to decide whether the failure reaches the user, so the side that aborts
/// and the side that judges the abort share one spelling.
public enum ClipboardStreamAbortCode: String, CaseIterable, Sendable {
    // MARK: - Request rejection

    /// The request names a generation this side has already moved past, or was
    /// dropped when a newer offer superseded it.
    case requestStale = "request.stale"

    /// The request's transfer id names a representation outside the offered set.
    case requestRange = "request.range"

    /// The requested UTI does not match the representation offered at that index.
    case requestUTI = "request.uti"

    /// Begin arrived for a transfer the receiver had already cancelled.
    case requestCancelled = "request.cancelled"

    // MARK: - Retirement and supersession

    /// This side tore the transfer down locally — a channel teardown or a
    /// cancelled generation, not a failure of the transfer itself.
    case cancelled = "cancelled"

    /// The user cancelled the gesture that owned the transfer.
    case userCancelled = "user.cancelled"

    /// A newer offer replaced the one being sent.
    case superseded = "superseded"

    // MARK: - Source and send side

    /// The sender could not read the source representation.
    case readError = "read.error"

    /// A frame carrying the transfer could not be written to the channel.
    case sendFailed = "send.failed"

    /// The peer stopped acknowledging received bytes.
    case ackTimeout = "ack.timeout"

    // MARK: - Framing and integrity

    /// A chunk's offset does not continue from the bytes already received.
    case offsetGap = "offset.gap"

    /// A chunk carries no bytes.
    case chunkEmpty = "chunk.empty"

    /// A chunk exceeds the negotiated maximum chunk size.
    case chunkTooLarge = "chunk.too.large"

    /// The payload runs past the size the offer advertised.
    case sizeOverrun = "size.overrun"

    /// Undrained chunks backed up past the receiver's in-memory budget.
    case flowOverrun = "flow.overrun"

    /// The bytes received do not add up to the total End declares.
    case sizeMismatch = "size.mismatch"

    /// The payload's SHA-256 does not match the digest End declares.
    case digestMismatch = "digest.mismatch"

    /// The payload's shape is one this receiver cannot take — an inline
    /// representation past the resident cap, for instance.
    case payloadUnsupported = "payload.unsupported"

    /// A payload arrived for a transfer that expected none.
    case payloadUnexpected = "payload.unexpected"

    /// The delivered payload is not what its declared shape promised.
    case payloadInvalid = "payload.invalid"

    // MARK: - Staging and landing

    /// The receiving side has no room to stage the streamed bytes.
    case diskFull = "disk.full"

    /// Writing the streamed bytes to their staging file failed.
    case writeError = "write.error"

    /// Unpacking a streamed directory archive failed.
    case extractError = "extract.error"

    /// The staging destination could not be prepared or is missing.
    case stageError = "stage.error"

    /// The staged file could not be mapped back into memory.
    case mapError = "map.error"

    // MARK: - Timeouts

    /// No chunk arrived within the receiver's inactivity window.
    case stallTimeout = "stall.timeout"

    /// The receiver's paste gesture gave up waiting for the transfer.
    case pasteTimeout = "paste.timeout"
}

extension ClipboardStreamAbortCode {
    /// Codes that retire a transfer quietly rather than reporting a failure: a
    /// local teardown or supersession the receiver reports, the sending side
    /// dropping a superseded offer, and the peer rejecting a request for a
    /// generation it has moved past.
    ///
    /// Neither side raises an issue for these — whatever superseded the offer
    /// publishes its own explainer, and a teardown is not the user's problem to
    /// act on.
    public static let retiring: Set<ClipboardStreamAbortCode> = [
        .cancelled, .superseded, .requestStale, .userCancelled,
    ]
}
