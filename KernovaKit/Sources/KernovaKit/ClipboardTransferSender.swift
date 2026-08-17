import Foundation

/// How a transfer's data connection is obtained.
///
/// macOS guests only ever *initiate* vsock connections, so one side is handed a
/// descriptor its listener accepted and the other dials for it — the single
/// axis on which the two roles differ.
public enum ClipboardTransferLink: Sendable {
    /// A descriptor a data listener accepted.
    case accepted(Int32)
    /// A dialler that connects to the peer's data port and returns the
    /// descriptor.
    case dial(@Sendable () throws -> Int32)
}

/// Streams one clipboard representation onto its own vsock data connection:
/// the descriptor's `ClipboardTransferReply`, then the payload bytes, then the
/// 33-byte trailer, then EOF.
///
/// A small inline representation streams raw; every other representation — a
/// file, a folder, an oversize inline payload — is encoded onto the socket as
/// an LZ4 AppleArchive as it streams, so the receiver's disk path is one
/// extract pipeline whatever the payload.
///
/// Everything runs on the transfer's own serial queue: the encode and the
/// socket writes are one call stack, and `write(2)` parking on a full send
/// buffer *is* the flow control. Nothing above it counts credit
/// (docs/research/2026-08-17-vsock-stalled-receiver-and-accept-latency.md).
public final class ClipboardTransferSender: @unchecked Sendable {
    /// Why this side stopped streaming, carried out through AppleArchive, which
    /// rewraps whatever a stream callback throws.
    private enum SenderStop: Error {
        case abort(ClipboardStreamAbortCode)
    }

    /// Identifies the transfer this connection carries.
    public let transferID: UInt64
    /// The offer generation the representation belongs to.
    public let generation: UInt64

    private let link: ClipboardTransferLink
    private let role: ClipboardDataConnection.Role
    private let socketTimeout: TimeInterval
    private let clock: any EngineClock
    private let maxResidentInlineBytes: Int
    private let onTransferTimed: (@Sendable (ClipboardTransferMetrics) -> Void)?

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var retiredAs: ClipboardStreamAbortCode?
    /// The first stop this side raised, kept apart from what the archive
    /// reports, since AppleArchive rewraps an error thrown out of a callback.
    private let stopBox = ArchiveRefusalBox()

    /// Creates a sender for one transfer.
    ///
    /// - Parameters:
    ///   - transferID: identifies the transfer the reply names.
    ///   - generation: the offer generation `isCurrent` is re-checked against.
    ///   - link: how the connection is obtained.
    ///   - role: which end of the connection this is, deciding whether the send
    ///     buffer is raised on it.
    ///   - clock: the timeline the stage timings are measured on.
    ///   - socketTimeout: the connection's `SO_RCVTIMEO`/`SO_SNDTIMEO`.
    ///   - maxResidentInlineBytes: the largest inline payload streamed raw; a
    ///     larger one is archived so the receiver never holds it whole.
    ///   - onTransferTimed: fired off the caller's actor once per *successful*
    ///     transfer, carrying its stage timings. A transfer that aborts reports
    ///     nothing, since a partial figure would read as a rate.
    public init(
        transferID: UInt64,
        generation: UInt64,
        link: ClipboardTransferLink,
        role: ClipboardDataConnection.Role,
        clock: any EngineClock = makePlatformEngineClock(),
        socketTimeout: TimeInterval = ClipboardStreamTuning.dataSocketTimeout,
        maxResidentInlineBytes: Int = ClipboardStreamTuning.maxResidentInlineBytes,
        onTransferTimed: (@Sendable (ClipboardTransferMetrics) -> Void)? = nil
    ) {
        self.transferID = transferID
        self.generation = generation
        self.link = link
        self.role = role
        self.clock = clock
        self.socketTimeout = socketTimeout
        self.maxResidentInlineBytes = max(0, maxResidentInlineBytes)
        self.onTransferTimed = onTransferTimed
        self.queue = DispatchQueue(
            label: "app.kernova.clipboard.transfer-send.\(transferID)", qos: .userInitiated)
    }

    /// Begins streaming `representation` on the transfer's own queue.
    ///
    /// Refuses up front — a reply carrying `disk.full` and no bytes — when the
    /// requester's `maxAcceptByteCount` cannot hold the payload the offer
    /// advertised, and aborts with a `superseded` trailer once
    /// `isCurrent(generation)` goes false.
    ///
    /// - Parameters:
    ///   - representation: what to stream; a file-backed or folder source must
    ///     stay readable for the whole transfer.
    ///   - maxAcceptByteCount: the requester's payload ceiling, in the unit the
    ///     offer advertised — the payload the requester writes, never the
    ///     compressed bytes on the wire.
    ///   - isInline: whether the receiver delivers the payload as pasteboard
    ///     bytes; mirrored into the reply.
    ///   - isCurrent: supersession check, called on the transfer's queue before
    ///     each socket write.
    ///   - onProgress: fired off the caller's actor as bytes leave, carrying
    ///     the cumulative `(bytesSent, totalBytes)` in the unit the offer
    ///     advertised. An archived transfer reports `0` for the total — the
    ///     progress tracker keeps the offer's own figure.
    ///   - onComplete: fired off the caller's actor exactly once when the
    ///     transfer ends, with `success` true only when every byte was streamed
    ///     and the completion trailer written.
    public func start(
        representation: ClipboardContent.Representation,
        maxAcceptByteCount: UInt64,
        isInline: Bool,
        isCurrent: @escaping @Sendable (UInt64) -> Bool,
        onProgress: (@Sendable (_ bytesSent: Int, _ totalBytes: Int) -> Void)? = nil,
        onComplete: (@Sendable (_ success: Bool) -> Void)? = nil
    ) {
        queue.async { [self] in
            run(
                representation: representation, maxAcceptByteCount: maxAcceptByteCount,
                isInline: isInline, isCurrent: isCurrent, onProgress: onProgress,
                onComplete: onComplete)
        }
    }

    /// Retires the transfer, naming the reason the trailer will carry.
    ///
    /// Safe from any thread and idempotent — the first reason wins. The reason
    /// is honored before the next socket write, so a peer that is reading sees
    /// it immediately; one that has stopped reading sees it when the send
    /// timeout releases the parked write, having not been waiting for it.
    public func cancel(_ code: ClipboardStreamAbortCode) {
        lock.withLock { if retiredAs == nil { retiredAs = code } }
    }

    // MARK: - Private

    private var retirement: ClipboardStreamAbortCode? { lock.withLock { retiredAs } }

    /// What crosses the wire: raw bytes for an inline payload the receiver can
    /// hold resident, an archive for everything else.
    private enum Payload {
        case raw(Data)
        case archived(ClipboardArchiveSource)
    }

    private func run(
        representation: ClipboardContent.Representation,
        maxAcceptByteCount: UInt64,
        isInline: Bool,
        isCurrent: @escaping @Sendable (UInt64) -> Bool,
        onProgress: (@Sendable (_ bytesSent: Int, _ totalBytes: Int) -> Void)?,
        onComplete: (@Sendable (_ success: Bool) -> Void)?
    ) {
        // Declared first so it ends last: the interval covers the whole
        // transfer, `onComplete` included.
        let signpost = ClipboardSignposts.transfers.beginInterval(
            "Clipboard send", id: ClipboardSignposts.transfers.makeSignpostID())
        defer { ClipboardSignposts.transfers.endInterval("Clipboard send", signpost) }

        // `onComplete` must fire on every exit path so the owner can clear any
        // progress UI; it runs *after* the connection is closed (defers run
        // LIFO), so a peer woken by the close is already past its own terminal
        // by the time the owner hears about this one.
        var didComplete = false
        defer { onComplete?(didComplete) }

        let beganAt = clock.now
        guard let fd = openConnection() else { return }
        defer { ClipboardDataConnection.end(fd: fd) }

        let advertisedByteCount = representation.byteCount
        // Refuse a transfer the requester cannot accept rather than stream
        // bytes that will be dropped. Any ceiling other than
        // `unlimitedAcceptByteCount` — including 0 — is a real one.
        if maxAcceptByteCount != ClipboardStreamTuning.unlimitedAcceptByteCount,
            UInt64(advertisedByteCount) > maxAcceptByteCount
        {
            refuse(fd: fd, code: .diskFull, message: "Requester cannot accept \(advertisedByteCount) bytes")
            return
        }
        if let code = retirement {
            refuse(fd: fd, code: code, message: "The transfer was retired before it started")
            return
        }
        guard isCurrent(generation) else {
            refuse(fd: fd, code: .superseded, message: "Offer superseded")
            return
        }

        guard let payload = classify(representation, isInline: isInline, fd: fd) else { return }
        let isArchive: Bool
        let declaredByteCount: Int
        switch payload {
        case .raw(let data):
            isArchive = false
            declaredByteCount = data.count
        case .archived:
            isArchive = true
            declaredByteCount = 0
        }
        guard
            writeReply(
                fd: fd, isArchive: isArchive, isInline: isInline,
                totalBytes: UInt64(declaredByteCount))
        else { return }

        let streamedFrom = clock.now
        let writer = ClipboardPayloadWriter(fd: fd, clock: clock) { [self] in
            if let code = retirement { try raise(code) }
            guard isCurrent(generation) else { try raise(.superseded) }
        }
        let counted = ArchiveByteCounter()
        var failure: ClipboardStreamAbortCode?
        do {
            switch payload {
            case .raw(let data):
                try stream(data, through: writer, onProgress: onProgress)
            case .archived(let source):
                try stream(
                    source, through: writer, counted: counted,
                    maxAcceptByteCount: maxAcceptByteCount, onProgress: onProgress)
            }
        } catch {
            failure = code(for: error)
        }

        let trailer =
            failure.map { ClipboardTransferTrailer(ending: .aborted(rawCode: $0.rawValue)) }
            ?? ClipboardTransferTrailer(ending: .complete(digest: writer.digest()))
        // Best-effort: a connection that died under the payload cannot carry the
        // reason it died for, and the peer already knows.
        try? ClipboardDataConnection.writeTrailer(trailer, fd: fd)
        guard failure == nil else { return }
        didComplete = true

        guard let onTransferTimed else { return }
        // What the peer holds once it has unpacked this payload, where the
        // source can say exactly — a one-entry archive expands to precisely the
        // bytes that went in, so this is the same figure the receiver reports
        // for the same transfer and the two log lines compare directly. A folder
        // has no exact figure until it has been walked, so it falls back to the
        // uncompressed archive stream, which carries per-entry headers too.
        let payloadByteCount: Int
        switch payload {
        case .raw(let data): payloadByteCount = data.count
        case .archived(.file(_, _, let byteCount)): payloadByteCount = byteCount
        case .archived(.blob(let data, _)): payloadByteCount = data.count
        case .archived(.directory): payloadByteCount = counted.value
        }
        let completedAt = clock.now
        onTransferTimed(
            ClipboardTransferMetrics(
                transferID: transferID,
                uti: representation.uti,
                byteCount: payloadByteCount,
                wireByteCount: writer.byteCount,
                duration: beganAt.seconds(to: completedAt),
                detail: .outbound(
                    .init(
                        isArchived: isArchive,
                        timeToFirstByte: writer.firstByteInstant.map { beganAt.seconds(to: $0) },
                        sourceWait: max(
                            0, streamedFrom.seconds(to: completedAt) - writer.socketWait))))
        )
    }

    /// Obtains the connection and applies its socket options, or gives up.
    private func openConnection() -> Int32? {
        let fd: Int32
        switch link {
        case .accepted(let accepted):
            fd = accepted
        case .dial(let dial):
            guard let dialled = try? dial() else { return nil }
            fd = dialled
        }
        ClipboardDataConnection.applySocketOptions(fd: fd, role: role, timeout: socketTimeout)
        return fd
    }

    /// Decides how `representation` crosses, or refuses the transfer.
    private func classify(
        _ representation: ClipboardContent.Representation, isInline: Bool, fd: Int32
    ) -> Payload? {
        switch representation.source {
        case .inMemory(let data) where isInline && data.count <= maxResidentInlineBytes:
            return .raw(data)
        case .file(let url, let byteCount, _) where isInline && byteCount <= maxResidentInlineBytes:
            // An inline payload is resident bytes on both ends, so resolve the
            // file to bytes here — bounded by the threshold the receiver holds
            // it resident under — rather than stream it raw from disk. The size
            // is re-read first: a file that grew past the threshold since the
            // offer's stat is archived from disk, as any oversize payload is,
            // rather than loaded whole.
            let currentByteCount =
                (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? byteCount
            if currentByteCount > maxResidentInlineBytes {
                return .archived(
                    .file(
                        url, name: Self.entryName(for: representation),
                        byteCount: currentByteCount))
            }
            guard let data = try? Data(contentsOf: url), data.count <= maxResidentInlineBytes
            else {
                refuse(fd: fd, code: .readError, message: "Cannot read source file")
                return nil
            }
            return .raw(data)
        case .pendingRemote:
            // The sender is only ever handed materialized reps we offered; a
            // not-yet-pulled placeholder has no bytes to stream.
            assertionFailure("Cannot stream a pending-remote representation")
            refuse(
                fd: fd, code: .readError,
                message: "Cannot stream a pending-remote representation")
            return nil
        case .inMemory(let data):
            return .archived(.blob(data, name: Self.entryName(for: representation)))
        case .file(let url, let byteCount, _):
            return .archived(
                .file(url, name: Self.entryName(for: representation), byteCount: byteCount))
        case .directory(let url, _):
            return .archived(.directory(url))
        }
    }

    /// The archive entry name for a one-entry payload: the representation's
    /// filename, which is what the receiver's extract will name the file.
    private static func entryName(for representation: ClipboardContent.Representation) -> String {
        FinderStyleUniquing.sanitizedComponent(
            representation.filename.isEmpty ? "data" : representation.filename)
    }

    /// Streams a raw payload in socket-sized blocks, so progress advances with
    /// the bytes rather than once at the end.
    private func stream(
        _ data: Data, through writer: ClipboardPayloadWriter,
        onProgress: (@Sendable (_ bytesSent: Int, _ totalBytes: Int) -> Void)?
    ) throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + ClipboardStreamTuning.dataReadBufferBytes, data.endIndex)
            try writer.write(data[offset..<end])
            offset = end
            onProgress?(writer.byteCount, data.count)
        }
    }

    /// Encodes an archived payload straight onto the socket, enforcing the
    /// requester's ceiling in payload units as the archive is produced.
    private func stream(
        _ source: ClipboardArchiveSource, through writer: ClipboardPayloadWriter,
        counted: ArchiveByteCounter, maxAcceptByteCount: UInt64,
        onProgress: (@Sendable (_ bytesSent: Int, _ totalBytes: Int) -> Void)?
    ) throws {
        let ceiling = maxAcceptByteCount
        let failure = ClipboardArchiveCodec.encode(
            source, into: ClipboardArchivePayloadSink(writer: writer), counted: counted
        ) { [self] produced in
            // Measured in the unit the ceiling is stated in: the payload the
            // requester will write, not the archive on the wire, which
            // compression can make ~100× smaller. A payload whose size was
            // knowable up front was already refused before the reply.
            if ceiling != ClipboardStreamTuning.unlimitedAcceptByteCount,
                UInt64(produced) > ceiling
            {
                try raise(.diskFull)
            }
            // `0` leaves the tracker on the expectation the unit was opened with
            // — the offer's figure — so the numerator has to be in that unit
            // too, which for an archive is what has been encoded rather than
            // what the wire has carried.
            onProgress?(produced, 0)
        }
        // The connection's own failure outranks a codec that returned
        // normally: AppleArchive can report success over a stream callback
        // whose write failed, which would end the transfer with a completion
        // trailer over a payload the peer never received.
        if let failure = failure ?? writer.failure { throw stopBox.value ?? failure }
    }

    /// Records and throws this side's own reason for stopping, so it survives
    /// AppleArchive rewrapping whatever a stream callback throws.
    private func raise(_ code: ClipboardStreamAbortCode) throws -> Never {
        let stop = SenderStop.abort(code)
        stopBox.value = stop
        throw stop
    }

    /// The abort code `error` ends the transfer with.
    private func code(for error: Error) -> ClipboardStreamAbortCode {
        if case SenderStop.abort(let code) = error { return code }
        if let connection = error as? ClipboardDataConnectionError {
            switch connection {
            case .timedOut: return .stallTimeout
            default: return .sendFailed
            }
        }
        return .readError
    }

    /// Writes the descriptor the payload follows.
    private func writeReply(fd: Int32, isArchive: Bool, isInline: Bool, totalBytes: UInt64) -> Bool {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardTransferReply = Kernova_V1_ClipboardTransferReply.with {
            $0.transferID = transferID
            $0.isArchive = isArchive
            $0.isInline = isInline
            $0.totalBytes = totalBytes
        }
        do {
            try ClipboardDataConnection.writeFrame(frame, fd: fd)
            return true
        } catch {
            return false
        }
    }

    /// Answers a request this side will not serve: a reply naming the reason,
    /// no payload, no trailer.
    private func refuse(fd: Int32, code: ClipboardStreamAbortCode, message: String) {
        try? ClipboardDataConnection.writeFrame(
            .clipboardTransferRefusal(transferID: transferID, code: code, message: message), fd: fd)
    }
}
