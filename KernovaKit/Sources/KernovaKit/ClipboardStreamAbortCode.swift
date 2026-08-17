import Foundation

/// Stable machine-readable reasons a transfer ended, named
/// `<stage>.<condition>`.
///
/// The raw value is what a refusal reply or an abort trailer carries, and what
/// the receiving side matches on to decide whether the failure reaches the
/// user, so the side that aborts and the side that judges the abort share one
/// spelling.
public enum ClipboardStreamAbortCode: String, CaseIterable, Sendable {
    // MARK: - Request rejection

    /// The request names a generation this side has already moved past, or was
    /// dropped when a newer offer superseded it.
    case requestStale = "request.stale"

    /// The request's transfer id names a representation outside the offered set.
    case requestRange = "request.range"

    /// The requested UTI does not match the representation offered at that index.
    case requestUTI = "request.uti"

    /// The connection named a transfer the receiver had already cancelled.
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

    /// The transfer's bytes could not be written to its connection.
    case sendFailed = "send.failed"

    // MARK: - Framing and integrity

    /// The payload runs past the size the offer advertised.
    case sizeOverrun = "size.overrun"

    /// The stream ended before its trailer, so what arrived is a prefix of the
    /// payload rather than the payload.
    case sizeMismatch = "size.mismatch"

    /// The payload's SHA-256 does not match the digest its trailer declares.
    case digestMismatch = "digest.mismatch"

    /// The payload's shape is one this receiver cannot take — an inline
    /// representation past the resident cap, for instance.
    case payloadUnsupported = "payload.unsupported"

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

    /// A read or write on the data connection reached the socket's own
    /// timeout with no bytes moving.
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

/// Why an inbound transfer failed, surfaced to the owning service.
public struct ClipboardStreamAbortInfo: Sendable, Equatable {
    /// Identifies the transfer that aborted.
    public let transferID: UInt64
    /// The abort reason, or `nil` for a code this build does not define.
    public let code: ClipboardStreamAbortCode?
    /// Exactly what the aborting side spelled, so a log line names an
    /// undefined code rather than losing it.
    public let rawCode: String
    /// Human-readable description of the failure.
    public let message: String
    /// Bytes the transfer needed, for a `disk.full` abort.
    public let neededBytes: Int?
    /// Bytes available on the staging volume, for a `disk.full` abort.
    public let availableBytes: Int?

    /// Whether the abort retires the transfer quietly instead of reporting a
    /// failure.
    ///
    /// An undefined code is never retiring: an abort spelled in a way this
    /// build cannot read is a failure to surface, not one to swallow.
    public var isRetiring: Bool {
        guard let code else { return false }
        return ClipboardStreamAbortCode.retiring.contains(code)
    }

    /// Creates abort info for a failure this side raised, whose code is known
    /// by construction.
    public init(
        transferID: UInt64, code: ClipboardStreamAbortCode, message: String, neededBytes: Int?,
        availableBytes: Int?
    ) {
        self.transferID = transferID
        self.code = code
        self.rawCode = code.rawValue
        self.message = message
        self.neededBytes = neededBytes
        self.availableBytes = availableBytes
    }

    /// Creates abort info from what a peer wrote — its refusal reply or its
    /// abort trailer — the one construction that takes an arbitrary string,
    /// since the peer's spelling is untrusted.
    init(
        transferID: UInt64, rawCode: String, message: String, neededBytes: Int?,
        availableBytes: Int?
    ) {
        self.transferID = transferID
        self.code = ClipboardStreamAbortCode(rawValue: rawCode)
        self.rawCode = rawCode
        self.message = message
        self.neededBytes = neededBytes
        self.availableBytes = availableBytes
    }
}
