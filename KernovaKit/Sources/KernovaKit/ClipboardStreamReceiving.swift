import Foundation

/// Opens the append-only staging sink for one disk-streamed transfer.
public typealias ClipboardSinkFactory =
    @Sendable (_ generation: UInt64, _ filename: String) throws ->
    StagingSink

/// The clock-independent surface of `ClipboardStreamReceiver`, for holders that
/// must run below macOS 13 and so cannot store a concrete clock instantiation.
public protocol ClipboardStreamReceiving: AnyObject, Sendable {
    /// Begins an inbound transfer: free-space check, sink open, and the initial
    /// ack that tells the sender to go.
    func handleBegin(_ begin: Kernova_V1_ClipboardStreamBegin)

    /// Accepts one chunk of an in-flight transfer.
    func handleChunk(_ chunk: Kernova_V1_ClipboardChunk)

    /// Verifies and commits a completed transfer.
    func handleEnd(_ end: Kernova_V1_ClipboardStreamEnd)

    /// Tears down an inbound transfer on a peer `ClipboardStreamAbort`.
    func handleAbort(_ abort: Kernova_V1_ClipboardStreamAbort)

    /// Aborts every in-flight transfer for a superseded generation.
    func cancel(generation: UInt64)

    /// Aborts every in-flight transfer (channel teardown / capability disable).
    func cancelAll()

    /// Consumer-requested cancel of one lazy pull.
    func cancel(transferID: UInt64)

    /// Registers an off-actor delivery handler for a single transfer.
    func awaitTransfer(
        _ transferID: UInt64,
        onComplete: @escaping @Sendable (ClipboardContent.Representation) -> Void,
        onAbort: @escaping @Sendable (ClipboardStreamAbortInfo) -> Void,
        onProgress: (@Sendable (_ bytesReceived: Int, _ totalBytes: Int) -> Void)?
    )

    /// Deregisters a per-transfer delivery handler without firing it.
    func cancelAwait(_ transferID: UInt64)
}

extension ClipboardStreamReceiving {
    /// `awaitTransfer` without a progress handler.
    public func awaitTransfer(
        _ transferID: UInt64,
        onComplete: @escaping @Sendable (ClipboardContent.Representation) -> Void,
        onAbort: @escaping @Sendable (ClipboardStreamAbortInfo) -> Void
    ) {
        awaitTransfer(transferID, onComplete: onComplete, onAbort: onAbort, onProgress: nil)
    }
}

/// Builds a receiver on the platform-default clock — `ContinuousClock` on
/// macOS 13+, `CLOCK_MONOTONIC` below — erased for holders that run on 12.
public func makeClipboardStreamReceiver(
    channel: VsockChannel,
    staging: ClipboardFileStaging,
    windowBytes: Int = ClipboardStreamTuning.defaultWindowBytes,
    ackLatencyBound: TimeInterval = ClipboardStreamTuning.ackLatencyBound,
    stallTimeout: TimeInterval = ClipboardStreamTuning.inboundStallTimeout,
    maxResidentInlineBytes: Int = ClipboardStreamTuning.maxResidentInlineBytes,
    sinkFactory: ClipboardSinkFactory? = nil,
    onTransferTimed: (@Sendable (ClipboardTransferMetrics) -> Void)? = nil,
    onComplete: @escaping @Sendable (UInt64, ClipboardContent.Representation) -> Void,
    onAbort: @escaping @Sendable (ClipboardStreamAbortInfo) -> Void
) -> any ClipboardStreamReceiving {
    if #available(macOS 13.0, *) {
        return ClipboardStreamReceiver(
            clock: ContinuousEngineClock(),
            channel: channel,
            staging: staging,
            windowBytes: windowBytes,
            ackLatencyBound: ackLatencyBound,
            stallTimeout: stallTimeout,
            maxResidentInlineBytes: maxResidentInlineBytes,
            sinkFactory: sinkFactory,
            onTransferTimed: onTransferTimed,
            onComplete: onComplete,
            onAbort: onAbort
        )
    }
    return ClipboardStreamReceiver(
        clock: MonotonicEngineClock(),
        channel: channel,
        staging: staging,
        windowBytes: windowBytes,
        ackLatencyBound: ackLatencyBound,
        stallTimeout: stallTimeout,
        maxResidentInlineBytes: maxResidentInlineBytes,
        sinkFactory: sinkFactory,
        onTransferTimed: onTransferTimed,
        onComplete: onComplete,
        onAbort: onAbort
    )
}
