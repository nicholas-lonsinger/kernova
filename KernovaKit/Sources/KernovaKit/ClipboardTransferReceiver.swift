import Foundation

/// Reassembles one clipboard representation off its own vsock data connection.
///
/// A raw payload — an inline representation at or below
/// `maxResidentInlineBytes`, the only kind a peer sends raw — accumulates in
/// memory. Everything else arrives as an LZ4 AppleArchive and streams straight
/// into an extract pipeline under the free-space guard, so the payload lands on
/// disk as it arrives and no archive is staged: a file becomes the archive's one
/// entry, a folder becomes the extracted tree, and an oversize inline
/// representation is mapped back and delivered as a resident `.inMemory`
/// payload, so inline content has no Kernova-imposed size cap.
///
/// Everything runs on the transfer's own serial queue, so the owning actor is
/// never blocked, and the 33-byte trailer is verified — size and SHA-256 both —
/// before anything is delivered (docs/CLIPBOARD.md §7).
public final class ClipboardTransferReceiver: @unchecked Sendable {
    /// What the pull that opened this connection expects to receive.
    ///
    /// Set from the pull's own registration, never from the wire: the side that
    /// asked for the representation is the side that read the offer describing
    /// it, so nothing on the data connection repeats offer metadata.
    public struct Plan: Sendable {
        /// The representation's UTI.
        public let uti: String
        /// The name a file representation lands under; empty for an inline one.
        public let filename: String
        /// The folder name a directory archive extracts into, or `nil` when the
        /// payload is a file or an inline representation.
        public let extractsDirectoryNamed: String?
        /// The size the offer advertised — exact for a file, a stat-walk
        /// estimate for a folder — which the extract is held to, and which the
        /// free-space pre-flight and paste ceiling were computed from.
        public let advertisedByteCount: Int

        /// Creates a plan for one awaited transfer.
        public init(
            uti: String, filename: String = "", extractsDirectoryNamed: String? = nil,
            advertisedByteCount: Int = 0
        ) {
            self.uti = uti
            self.filename = filename
            self.extractsDirectoryNamed = extractsDirectoryNamed
            self.advertisedByteCount = max(0, advertisedByteCount)
        }
    }

    /// How the connection this transfer arrives on is obtained, and what has
    /// already been read off it.
    public enum Source: Sendable {
        /// A descriptor a data listener accepted, whose reply the accept path
        /// already read to match this transfer.
        case accepted(fd: Int32, reply: Kernova_V1_ClipboardTransferReply)
        /// A dialler, followed by the request this side writes to open the
        /// transfer; the reply is then the first thing back.
        case dial(@Sendable () throws -> Int32, request: Kernova_V1_ClipboardTransferRequest)
    }

    /// Why this side stopped, and what the owner is told.
    ///
    /// The reason is a raw code rather than a case, so a spelling this build
    /// does not define — a peer's abort trailer naming one — reaches the owner
    /// as written instead of being flattened into something it recognizes.
    private struct ReceiveStop: Error {
        let rawCode: String
        let message: String
        var neededBytes: Int?
        var availableBytes: Int?

        init(code: ClipboardStreamAbortCode, message: String, neededBytes: Int? = nil, availableBytes: Int? = nil) {
            self.init(
                rawCode: code.rawValue, message: message, neededBytes: neededBytes,
                availableBytes: availableBytes)
        }

        init(rawCode: String, message: String, neededBytes: Int? = nil, availableBytes: Int? = nil) {
            self.rawCode = rawCode
            self.message = message
            self.neededBytes = neededBytes
            self.availableBytes = availableBytes
        }
    }

    /// Identifies the transfer this connection carries.
    public let transferID: UInt64
    /// The offer generation the transfer belongs to.
    public let generation: UInt64

    private let source: Source
    private let role: ClipboardDataConnection.Role
    private let socketTimeout: TimeInterval
    private let plan: Plan
    private let staging: ClipboardFileStaging
    private let clock: any EngineClock
    private let maxResidentInlineBytes: Int
    private let minimumExtractAllowance: Int
    private let extractPacingBytes: Int
    private let onTransferTimed: (@Sendable (ClipboardTransferMetrics) -> Void)?

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var descriptor: Int32?
    private var isCancelled = false
    /// The extract's live uncompressed total, so progress is reported in the
    /// unit the offer's figure is stated in rather than in compressed bytes.
    private var extracted: ArchiveByteCounter?
    /// The size a raw payload declared, which its progress is reported against.
    private var declaredTotalBytes = 0
    private var onProgress: (@Sendable (_ bytesReceived: Int, _ totalBytes: Int) -> Void)?

    /// Creates a receiver for one transfer.
    ///
    /// - Parameters:
    ///   - transferID: identifies the transfer the reply must name.
    ///   - generation: the offer generation the transfer belongs to.
    ///   - source: how the connection is obtained.
    ///   - role: which end of the connection this is.
    ///   - plan: what the pull expects to receive.
    ///   - staging: where an archived payload is extracted.
    ///   - clock: the timeline the stage timings are measured on.
    ///   - socketTimeout: the connection's `SO_RCVTIMEO`/`SO_SNDTIMEO`; a read
    ///     that reaches it is the stall.
    ///   - maxResidentInlineBytes: the most a raw payload may declare.
    ///   - minimumExtractAllowance: floor on what a streamed folder may extract
    ///     whatever its offer advertised.
    ///   - extractPacingBytes: output granularity at which the extract
    ///     re-checks its ceiling and the volume.
    ///   - onTransferTimed: fired just before completion, for a successful
    ///     transfer only.
    public init(
        transferID: UInt64,
        generation: UInt64,
        source: Source,
        role: ClipboardDataConnection.Role,
        plan: Plan,
        staging: ClipboardFileStaging,
        clock: any EngineClock = makePlatformEngineClock(),
        socketTimeout: TimeInterval = ClipboardStreamTuning.dataSocketTimeout,
        maxResidentInlineBytes: Int = ClipboardStreamTuning.maxResidentInlineBytes,
        minimumExtractAllowance: Int = ClipboardStreamTuning.minimumExtractAllowance,
        extractPacingBytes: Int = ClipboardStreamTuning.extractPacingBytes,
        onTransferTimed: (@Sendable (ClipboardTransferMetrics) -> Void)? = nil
    ) {
        self.transferID = transferID
        self.generation = generation
        self.source = source
        self.role = role
        self.plan = plan
        self.staging = staging
        self.clock = clock
        self.socketTimeout = socketTimeout
        self.maxResidentInlineBytes = max(0, maxResidentInlineBytes)
        self.minimumExtractAllowance = max(1, minimumExtractAllowance)
        self.extractPacingBytes = max(1, extractPacingBytes)
        self.onTransferTimed = onTransferTimed
        self.queue = DispatchQueue(
            label: "app.kernova.clipboard.transfer-recv.\(transferID)", qos: .userInitiated)
    }

    /// Opens the connection and receives the transfer on its own queue.
    ///
    /// Exactly one of `onComplete` and `onAbort` fires, off the caller's actor,
    /// on the transfer's queue.
    public func start(
        onComplete: @escaping @Sendable (ClipboardContent.Representation) -> Void,
        onAbort: @escaping @Sendable (ClipboardStreamAbortInfo) -> Void,
        onProgress: (@Sendable (_ bytesReceived: Int, _ totalBytes: Int) -> Void)? = nil
    ) {
        lock.withLock { self.onProgress = onProgress }
        queue.async { [self] in
            run(onComplete: onComplete, onAbort: onAbort)
        }
    }

    /// Abandons the transfer, waking a read parked on a peer that has gone
    /// quiet.
    ///
    /// Safe from any thread and idempotent. The outcome the owner sees is
    /// `cancelled`, which retires the transfer quietly rather than reporting a
    /// failure.
    public func cancel() {
        // The shutdown happens under the lock the descriptor is cleared under,
        // so a cancellation racing the connection's own close can never reach a
        // descriptor number the system has already handed to someone else.
        lock.withLock {
            isCancelled = true
            guard let descriptor else { return }
            ClipboardDataConnection.interrupt(fd: descriptor)
        }
    }

    // MARK: - Private

    private var cancelled: Bool { lock.withLock { isCancelled } }

    private func run(
        onComplete: @escaping @Sendable (ClipboardContent.Representation) -> Void,
        onAbort: @escaping @Sendable (ClipboardStreamAbortInfo) -> Void
    ) {
        let signpost = ClipboardSignposts.transfers.beginInterval(
            "Clipboard receive", id: ClipboardSignposts.transfers.makeSignpostID())
        defer { ClipboardSignposts.transfers.endInterval("Clipboard receive", signpost) }

        let beganAt = clock.now
        guard let fd = openConnection() else {
            onAbort(abortInfo(ReceiveStop(code: .cancelled, message: "The connection never opened")))
            return
        }
        defer { closeConnection(fd) }

        do {
            let outcome = try receive(fd: fd, beganAt: beganAt)
            onComplete(outcome)
        } catch {
            onAbort(abortInfo(stop(for: error)))
        }
    }

    /// Obtains the connection, writes the request when this side dials, and
    /// applies the socket options.
    private func openConnection() -> Int32? {
        guard !cancelled else { return nil }
        let fd: Int32
        switch source {
        case .accepted(let accepted, _):
            fd = accepted
        case .dial(let dial, _):
            guard let dialled = try? dial() else { return nil }
            fd = dialled
        }
        ClipboardDataConnection.applySocketOptions(fd: fd, role: role, timeout: socketTimeout)
        lock.withLock { descriptor = fd }
        // A cancellation that landed while the connection was being opened had
        // nothing to interrupt, so honor it here rather than start a transfer
        // nobody is waiting on.
        guard !cancelled else {
            closeConnection(fd)
            return nil
        }
        // The request is what opens a transfer this side dials for; the reply
        // is then the first thing back.
        if case .dial(_, let request) = source {
            var frame = Frame()
            frame.protocolVersion = 1
            frame.clipboardTransferRequest = request
            guard (try? ClipboardDataConnection.writeFrame(frame, fd: fd)) != nil else {
                closeConnection(fd)
                return nil
            }
        }
        return fd
    }

    /// Ends the connection and forgets its descriptor.
    private func closeConnection(_ fd: Int32) {
        lock.withLock { descriptor = nil }
        ClipboardDataConnection.end(fd: fd)
    }

    /// Reads the reply, the payload and the trailer, and delivers what arrived.
    private func receive(fd: Int32, beganAt: EngineInstant) throws
        -> ClipboardContent.Representation
    {
        let reply = try readReply(fd: fd)
        guard reply.refusalCode.isEmpty else {
            throw ReceiveStop(rawCode: reply.refusalCode, message: reply.refusalMessage)
        }
        lock.withLock { declaredTotalBytes = Int(clamping: reply.totalBytes) }
        let reader = ClipboardPayloadReader(fd: fd) { [weak self] received in
            self?.report(received)
        }
        let firstByteAt = clock.now
        let outcome: (representation: ClipboardContent.Representation, byteCount: Int)
        if reply.isArchive {
            outcome = try receiveArchive(reply: reply, reader: reader)
        } else {
            outcome = try receiveRaw(reply: reply, reader: reader)
        }
        if let onTransferTimed {
            let completedAt = clock.now
            onTransferTimed(
                ClipboardTransferMetrics(
                    transferID: transferID,
                    uti: plan.uti,
                    byteCount: outcome.byteCount,
                    wireByteCount: reader.byteCount,
                    duration: beganAt.seconds(to: completedAt),
                    detail: .inbound(
                        .init(
                            streamedToDisk: reply.isArchive,
                            streamingDuration: firstByteAt.seconds(to: completedAt)))))
        }
        return outcome.representation
    }

    /// Reads the descriptor the payload follows, from the fd or from the accept
    /// path that already took it.
    private func readReply(fd: Int32) throws -> Kernova_V1_ClipboardTransferReply {
        let reply: Kernova_V1_ClipboardTransferReply
        switch source {
        case .accepted(_, let accepted):
            reply = accepted
        case .dial:
            let frame = try ClipboardDataConnection.readFrame(fd: fd)
            guard case .clipboardTransferReply(let read) = frame.payload else {
                throw ClipboardDataConnectionError.unexpectedFrame
            }
            reply = read
        }
        guard reply.transferID == transferID else {
            throw ReceiveStop(
                code: .payloadInvalid,
                message: "The reply names transfer \(reply.transferID), not \(transferID)")
        }
        return reply
    }

    // MARK: - Raw payloads

    private func receiveRaw(
        reply: Kernova_V1_ClipboardTransferReply, reader: ClipboardPayloadReader
    ) throws -> (representation: ClipboardContent.Representation, byteCount: Int) {
        // Raw is how a peer sends what fits in RAM, and nothing else: refusing
        // anything larger, or anything not inline, is what bounds the buffer a
        // misbehaving peer could otherwise grow without limit — there is no
        // staging file to spill it to. A pull primed as a folder is refused too,
        // so a peer claiming `is_inline` cannot have a folder's request answered
        // with a file.
        guard reply.isInline, plan.extractsDirectoryNamed == nil,
            reply.totalBytes <= UInt64(maxResidentInlineBytes)
        else {
            throw ReceiveStop(
                code: .payloadUnsupported,
                message: "A raw payload must be inline, fit in memory, and answer no folder pull")
        }
        let declared = Int(clamping: reply.totalBytes)
        let data: Data
        do {
            data = try reader.readExactly(declared)
        } catch {
            throw stop(for: error, shortPayloadFrom: reader)
        }
        try reader.drain(allowance: 0)
        try verify(reader.trailer(), against: reader)
        return (
            ClipboardContent.Representation(
                uti: plan.uti, source: .inMemory(data), filename: plan.filename),
            data.count
        )
    }

    // MARK: - Archived payloads

    private func receiveArchive(
        reply: Kernova_V1_ClipboardTransferReply, reader: ClipboardPayloadReader
    ) throws -> (representation: ClipboardContent.Representation, byteCount: Int) {
        let advertised = plan.advertisedByteCount
        guard staging.hasCapacity(forByteCount: advertised) else { throw diskFull(needed: advertised) }
        let ceiling = extractCeiling(
            forAdvertisedByteCount: advertised, isDirectory: plan.extractsDirectoryNamed != nil)
        let destination: URL
        do {
            if let name = plan.extractsDirectoryNamed {
                destination = try staging.reserveDirectory(generation: generation, name: name)
            } else {
                destination = try staging.reserveScratchDirectory(generation: generation)
            }
        } catch {
            throw ReceiveStop(code: .stageError, message: "Cannot open the extract destination")
        }

        let counted = ArchiveByteCounter()
        lock.withLock { extracted = counted }
        let refusal = ArchiveRefusalBox()
        let staging = self.staging
        let guarded = refusal.guarding { [self] written in
            // The decompressor takes a whole block of the archive before it
            // emits any of it, so arriving wire bytes are a poor clock for a
            // bar stated in payload units: report from the output instead, at
            // the guard's own cadence.
            report(written)
            // Paced by the payload being *written*, not by the archive arriving:
            // compression can reach ~100:1, so a guard clocked on wire bytes
            // would let ~100 MB land between checks and the margin would never
            // fire.
            guard written <= ceiling else {
                throw ClipboardArchiveStreamError.outputRefused(.overAdvertisedSize)
            }
            // Re-check the room left for what the offer said remains, so a
            // volume another writer is filling stops the transfer early rather
            // than at the margin.
            guard staging.hasCapacity(forByteCount: max(0, advertised - written)) else {
                throw ClipboardArchiveStreamError.outputRefused(.diskFull)
            }
        }
        let failure = ClipboardArchiveCodec.extract(
            from: ClipboardArchivePayloadSource(reader: reader), into: destination,
            counted: counted, pacingBytes: extractPacingBytes, onOutputAdvanced: guarded)

        if let refused = refusal.value {
            try? FileManager.default.removeItem(at: destination)
            throw stop(for: refused)
        }
        if let failure {
            try? FileManager.default.removeItem(at: destination)
            // The sender's own reason outranks the truncation it caused: an
            // archive cut short by a supersession must retire quietly rather
            // than report a corrupt payload.
            if let trailer = try? endingAfterFailure(reader),
                case .aborted(let rawCode) = trailer.ending
            {
                throw stop(forAbortedTrailer: rawCode)
            }
            throw stop(for: failure)
        }

        do {
            try reader.drain(allowance: ClipboardStreamTuning.archiveTailAllowance)
            try verify(reader.trailer(), against: reader)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return try finishStaged(reply: reply, at: destination, counted: counted, reader: reader)
    }

    /// Drains what is left after a failed extract so the sender's trailer can be
    /// read, if it sent one.
    private func endingAfterFailure(_ reader: ClipboardPayloadReader) throws
        -> ClipboardTransferTrailer
    {
        try reader.drain(allowance: ClipboardStreamTuning.archiveTailAllowance)
        return try reader.trailer()
    }

    /// Turns the extracted tree into the representation the pull asked for.
    private func finishStaged(
        reply: Kernova_V1_ClipboardTransferReply, at destination: URL,
        counted: ArchiveByteCounter, reader: ClipboardPayloadReader
    ) throws -> (representation: ClipboardContent.Representation, byteCount: Int) {
        let digest = reader.digest()
        if plan.extractsDirectoryNamed != nil {
            // The rep's bytes are the tree at `destination`, so its size is the
            // tree's, not the compressed count the wire carried — which can be
            // ~100× lower and disagrees with the uncompressed estimate the offer
            // advertised for the same folder.
            let treeByteCount = counted.value
            return (
                ClipboardContent.Representation(
                    uti: plan.uti, fileURL: destination, byteCount: treeByteCount,
                    sha256: digest, filename: plan.filename, isDirectory: true),
                treeByteCount
            )
        }
        // A file's archive holds exactly one regular-file entry, extracted into
        // a scratch directory of its own so it keeps its exact name. Anything
        // else — a tree, a link, nothing — is a payload that does not match what
        // the offer described, and the peer that produced it is not trusted to
        // have meant well.
        guard let file = Self.singleRegularFile(in: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw ReceiveStop(
                code: .payloadInvalid, message: "The archive did not unpack to exactly one file")
        }
        // A file's advertised size is exact and the sender writes exactly that
        // many bytes, so the ceiling's header allowance is not payload a peer
        // may spend: hold a file to its offer to the byte. An inline payload is
        // exempt — one resolved from a file that grew since its offer is
        // legitimately larger, and it is bounded by the ceiling instead.
        if !reply.isInline, file.byteCount != plan.advertisedByteCount {
            try? FileManager.default.removeItem(at: destination)
            throw ReceiveStop(
                code: .sizeOverrun,
                message:
                    "The file unpacked to \(file.byteCount) bytes, its offer said \(plan.advertisedByteCount)"
            )
        }
        guard reply.isInline else {
            return (
                ClipboardContent.Representation(
                    uti: plan.uti, fileURL: file.url, byteCount: file.byteCount, sha256: digest,
                    filename: plan.filename),
                file.byteCount
            )
        }
        // An oversize inline rep: serve its bytes back as a resident `.inMemory`
        // payload through a memory-mapped read, so the pasteboard flavor is
        // unchanged while Kernova's added RAM stays near zero (CLIPBOARD.md
        // §1/§2/§8). On Darwin a `.mappedIfSafe` mapping stays valid after the
        // staged file is unlinked by a later generation sweep, so the mapped rep
        // needs no lifetime tracking.
        let mapped: Data
        do {
            mapped = try Data(contentsOf: file.url, options: .mappedIfSafe)
        } catch {
            throw ReceiveStop(
                code: .mapError,
                message: "Mapping the extracted inline file failed: \(error.localizedDescription)")
        }
        return (
            ClipboardContent.Representation(
                uti: plan.uti, source: .inMemory(mapped), filename: plan.filename),
            file.byteCount
        )
    }

    /// The one regular file directly inside `directory`, with its size, or `nil`
    /// when the directory holds anything else.
    private static func singleRegularFile(in directory: URL) -> (url: URL, byteCount: Int)? {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: []),
            entries.count == 1,
            let entry = entries.first,
            let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true
        else { return nil }
        return (entry, values.fileSize ?? 0)
    }

    /// How much an extract may write for a payload the offer advertised at
    /// `advertisedByteCount`.
    ///
    /// Nothing on the wire states an archive's unpacked size, so the figure the
    /// paste ceiling and the free-space pre-flight were computed from is the
    /// only one to hold it to. A file's is exact, so its ceiling is that plus
    /// the one entry header's allowance. A folder's is a stat-walk estimate,
    /// and its allowance is generous on purpose: the archive adds a header per
    /// entry to the file bytes the estimate sums, and a tree can legitimately
    /// grow a little between the copy-time walk and the paste-time encode.
    /// Doubling covers header overhead for any tree whose file bytes dominate,
    /// and the floor covers one whose estimate is zero or tiny — a scaffold of
    /// empty files — while staying far below any paste ceiling.
    func extractCeiling(forAdvertisedByteCount advertisedByteCount: Int, isDirectory: Bool) -> Int {
        guard isDirectory else {
            return advertisedByteCount.saturatingAdding(ClipboardStreamTuning.fileExtractAllowance)
        }
        let doubled = advertisedByteCount.saturatingAdding(advertisedByteCount)
        return max(doubled, minimumExtractAllowance)
    }

    // MARK: - Endings

    /// Checks the trailer that ended the payload.
    private func verify(_ trailer: ClipboardTransferTrailer, against reader: ClipboardPayloadReader)
        throws
    {
        switch trailer.ending {
        case .aborted(let rawCode):
            throw stop(forAbortedTrailer: rawCode)
        case .complete(let digest):
            guard digest == reader.digest() else {
                throw ReceiveStop(code: .digestMismatch, message: "SHA-256 mismatch at the trailer")
            }
        }
    }

    /// Reports arriving bytes to the pull, in the unit the offer's figure is in.
    private func report(_ receivedBytes: Int) {
        let (handler, extracted, declared) = lock.withLock {
            (onProgress, self.extracted, declaredTotalBytes)
        }
        // For an archive the wire count is compressed while every readout's
        // denominator is the offer's uncompressed figure, so report what the
        // extract has written instead — same unit, same scale.
        handler?(extracted?.value ?? receivedBytes, declared)
    }

    private func diskFull(needed: Int?) -> ReceiveStop {
        ReceiveStop(
            code: .diskFull, message: "Not enough disk space", neededBytes: needed,
            availableBytes: staging.availableCapacity().map { Int(clamping: $0) })
    }

    /// The stop a peer's abort trailer names.
    private func stop(forAbortedTrailer rawCode: String) -> ReceiveStop {
        ReceiveStop(rawCode: rawCode, message: "The sender ended the transfer")
    }

    /// The stop `error` ends the transfer with, honoring a local cancellation
    /// over whatever the interrupted read reported.
    private func stop(for error: Error, shortPayloadFrom reader: ClipboardPayloadReader? = nil)
        -> ReceiveStop
    {
        if let stop = error as? ReceiveStop { return stop }
        if cancelled {
            return ReceiveStop(code: .cancelled, message: "The transfer was cancelled")
        }
        if case ClipboardArchiveStreamError.outputRefused(let refusal) = error {
            switch refusal {
            case .diskFull:
                return diskFull(needed: plan.advertisedByteCount)
            case .overAdvertisedSize:
                return ReceiveStop(
                    code: .sizeOverrun,
                    message: "The payload unpacked to more than its offer advertised")
            }
        }
        if let connection = error as? ClipboardDataConnectionError {
            switch connection {
            case .timedOut:
                return ReceiveStop(code: .stallTimeout, message: "The sender stopped sending")
            case .truncated:
                // A sender that gave up mid-payload still wrote its reason, so
                // read it rather than report the short payload it left behind.
                let ending = reader.flatMap { try? $0.trailer() }?.ending
                if case .aborted(let rawCode)? = ending {
                    return stop(forAbortedTrailer: rawCode)
                }
                return ReceiveStop(
                    code: .sizeMismatch, message: "The stream ended before its trailer")
            case .trailingSurplus:
                return ReceiveStop(
                    code: .sizeOverrun,
                    message: "The sender streamed past the end of the payload")
            default:
                return ReceiveStop(code: .sizeMismatch, message: "The connection ended early")
            }
        }
        // A volume that filled between the output guard's last check and the
        // extract's own write surfaces from AppleArchive as an archive failure.
        // Naming that a corrupt payload sends the user off to retry the copy
        // instead of to free space, so the volume is asked before the codec is
        // believed.
        guard staging.hasCapacity(forByteCount: 0) else {
            return diskFull(needed: plan.advertisedByteCount)
        }
        return ReceiveStop(
            code: .extractError,
            message: "Unpacking the payload failed: \(error.localizedDescription)")
    }

    private func abortInfo(_ stop: ReceiveStop) -> ClipboardStreamAbortInfo {
        ClipboardStreamAbortInfo(
            transferID: transferID, rawCode: stop.rawCode, message: stop.message,
            neededBytes: stop.neededBytes, availableBytes: stop.availableBytes)
    }
}
