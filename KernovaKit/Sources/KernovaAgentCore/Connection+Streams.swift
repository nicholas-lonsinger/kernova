#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

extension Connection {
    // MARK: - Stream commands

    /// Opens a stream of `kind` with its encoded OPEN body; check `canOpen` first.
    @discardableResult
    public mutating func open(_ kind: StreamKind, body: Data) -> StreamID {
        guard canOpen(kind), let descriptor = descriptor(for: kind) else {
            misuse("open \(kind) that canOpen refuses")
            return .session
        }
        guard nextLocalID <= UInt64(UInt32.max) else {
            fatal(.streamIdsExhausted, "the next stream id would exceed 2^32-1")
            return .session
        }
        let id = StreamID(rawValue: UInt32(nextLocalID))
        nextLocalID += 2
        var record = StreamRecord(
            id: id, descriptor: descriptor, isLocal: true, isAccepted: true, bulkTarget: policy.bulkReceiveTarget)
        record.enqueue(.open(openPayload(kind, body: body)))
        raiseToBulkTarget(&record, viaQueue: true)
        record.wasWritable = sendPredicate(record)
        insert(record)
        if configuration.recordsTrace { trace.append(.localOpened(id, kind)) }
        return id
    }

    /// Queues one message on `id`; check `canSendMessage` first.
    public mutating func send(message: Data, on id: StreamID) {
        guard canSendMessage(message.count, on: id), let index = index(of: id) else {
            return misuse("send a message that is not sendable on stream \(id.rawValue)")
        }
        streams[index].sendWindow -= message.count
        streams[index].unsentMessages += 1
        streams[index].enqueue(.message(message))
        if configuration.recordsTrace { trace.append(.sent(id, isMessage: true, message)) }
        refreshWritable(at: index)
    }

    /// Queues raw DATA on `id`: 1 byte up to `min(writableData, 1 MiB)`.
    public mutating func send(data: Data, on id: StreamID) {
        guard let index = index(of: id), !data.isEmpty, data.count <= WireConstants.maxRawDataPayload,
            data.count <= writableData(at: index)
        else { return misuse("send \(data.count) raw bytes past writableData on stream \(id.rawValue)") }
        streams[index].sendWindow -= data.count
        streams[index].queuedRaw += data.count
        streams[index].enqueue(.data(data))
        connectionSendCredit -= data.count
        queuedRawTotal += data.count
        if configuration.recordsTrace { trace.append(.sent(id, isMessage: false, data)) }
    }

    /// Queues this side's END on `id` with the kind's END body.
    public mutating func end(_ id: StreamID, body: Data) {
        guard isAcceptingInput, let index = index(of: id), streams[index].canSend,
            body.count <= WireConstants.maxControlPayload
        else { return misuse("END on stream \(id.rawValue), which cannot send") }
        streams[index].enqueue(.end(body))
        if streams[index].phase == .remoteEnded {
            closeStream(at: index, .completed(remoteEndBody: streams[index].remoteEndBody))
        } else {
            streams[index].phase = .localEnded
        }
    }

    /// Resets `id`, which must not be completed or closed.
    public mutating func reset(_ id: StreamID, _ error: WireError) {
        guard isAcceptingInput, let index = index(of: id), streams[index].phase != .closed else {
            return misuse("RESET of stream \(id.rawValue), which is closed")
        }
        resetStream(at: index, error)
    }

    /// The owning machine finished with `byteCount` raw bytes of `id`.
    /// Ignored once the stream has closed (R5).
    public mutating func consumed(_ byteCount: Int, on id: StreamID) {
        guard isAcceptingInput, let index = index(of: id), streams[index].phase != .closed else { return }
        guard byteCount >= 0, byteCount <= streams[index].heldRaw else {
            return misuse("consumed \(byteCount) bytes of \(streams[index].heldRaw) held on stream \(id.rawValue)")
        }
        streams[index].heldRaw -= byteCount
        connectionHeldRaw -= byteCount
        streams[index].unreturned += byteCount
        connectionUnreturned += byteCount
        returnStreamCredit(at: index)
        returnConnectionCredit()
    }

    /// Caps how fast `id`'s stream credit returns: a token bucket of `burst`
    /// bytes refilled at `bytesPerSecond`.
    public mutating func setCreditReturnRate(_ bytesPerSecond: Int, burst: Int, on id: StreamID) {
        guard let index = index(of: id), bytesPerSecond > 0, burst > 0 else { return }
        streams[index].returnBucket = TokenBucket(capacity: burst, perSecond: bytesPerSecond, now: clock.raw)
    }

    // MARK: - Internals

    func openPayload(_ kind: StreamKind, body: Data) -> Data {
        var open = Kernova_V2_Open()
        open.kind = kind
        open.body = body
        return open.encoded
    }

    /// Queues RESET (or, before the OPEN left, drops the stream unsent) and closes it.
    mutating func resetStream(at index: Int, _ error: WireError) {
        if streams[index].openHandedOut {
            streams[index].pendingReset = error
        }
        closeStream(at: index, .resetLocally(error), discardingQueue: true)
    }

    /// Drops the stream's FIFO, refunding the connection credit of its raw DATA.
    mutating func discardQueue(at index: Int) {
        var record = streams[index]
        while record.hasQueuedFrames {
            if case .data(let bytes) = record.popFrame() {
                connectionSendCredit += bytes.count
                queuedRawTotal -= bytes.count
            }
        }
        record.queuedRaw = 0
        record.unsentMessages = 0
        streams[index] = record
    }

    /// Closes the stream (see `markClosed`), dropping its FIFO when
    /// `discardingQueue`, and retires the record once nothing is left to send.
    /// The FIFO goes only after the stream is closed, so the refund never wakes it.
    mutating func closeStream(at index: Int, _ closure: StreamClosure, discardingQueue: Bool = false) {
        guard streams[index].phase != .closed else { return }
        markClosed(at: index, closure)
        if discardingQueue { discardQueue(at: index) }
        if isAcceptingInput { returnConnectionCredit() }
        if streams[index].isRetired { streams.remove(at: index) }
    }

    /// Marks the stream closed, emits its one `streamClosed`, and credits its held
    /// raw bytes back to the connection.
    private mutating func markClosed(at index: Int, _ closure: StreamClosure) {
        let record = streams[index]
        streams[index].phase = .closed
        streams[index].pendingWindow = 0
        streams[index].returnBucket = nil
        if record.heldRaw > 0 {
            connectionHeldRaw -= record.heldRaw
            connectionUnreturned += record.heldRaw
            streams[index].heldRaw = 0
        }
        if record.isAccepted {
            emit(.streamClosed(record.id, closure), owner: record.owner)
        }
    }

    /// Closes every open stream with `closure`, then drops every FIFO. Pending
    /// RESETs survive a local close for streams whose OPEN left; everything else
    /// is dropped.
    mutating func closeAllStreams(_ closure: StreamClosure, keepPendingResets: Bool) {
        for index in streams.indices {
            if !keepPendingResets { streams[index].pendingReset = nil }
            if streams[index].phase != .closed { markClosed(at: index, closure) }
        }
        for index in streams.indices {
            discardQueue(at: index)
        }
        if isAcceptingInput { returnConnectionCredit() }
        streams.removeAll { $0.isRetired }
    }

    // MARK: - Credit return

    /// Sends unreturned stream credit once it reaches the threshold, within any rate cap.
    mutating func returnStreamCredit(at index: Int) {
        var record = streams[index]
        guard record.canReceive, record.unreturned >= record.replenishThreshold else { return }
        var amount = record.unreturned
        if var bucket = record.returnBucket {
            bucket.refill(clock.raw)
            guard bucket.tokens >= record.replenishThreshold else {
                record.returnBucket = bucket
                streams[index] = record
                return
            }
            amount = bucket.takeUpTo(amount)
            record.returnBucket = bucket
        }
        record.unreturned -= amount
        record.pendingWindow += amount
        record.receiveRemaining += amount
        streams[index] = record
    }

    /// Sends unreturned connection credit once it reaches the threshold.
    mutating func returnConnectionCredit() {
        guard connectionUnreturned >= policy.connectionReplenishThreshold else { return }
        pendingConnectionWindow += connectionUnreturned
        connectionReceiveRemaining += connectionUnreturned
        connectionUnreturned = 0
    }

    // MARK: - Writability

    /// The S4 predicate: raw senders, `writableData` ≥ 64 KiB; message senders,
    /// stream credit ≥ 64 KiB with no message unsent.
    func sendPredicate(_ record: StreamRecord) -> Bool {
        guard record.canSend, isAcceptingInput else { return false }
        switch record.sending {
        case .rawData:
            let writable = min(record.sendWindow, connectionSendCredit, policy.senderRawBudget - queuedRawTotal)
            return writable >= Limits.writableLowWater
        case .messages:
            return record.sendWindow >= Limits.writableLowWater && record.unsentMessages == 0
        case .nothing:
            return false
        }
    }

    mutating func refreshWritable(at index: Int) {
        let now = sendPredicate(streams[index])
        if now, !streams[index].wasWritable {
            emit(.writable(streams[index].id), owner: streams[index].owner)
        }
        streams[index].wasWritable = now
    }

    mutating func refreshAllWritable() {
        for index in streams.indices where streams[index].sending == .rawData {
            refreshWritable(at: index)
        }
    }

    // MARK: - Close

    /// A fatal error: every queue dropped, RESET(0) queued alone, every stream closed.
    mutating func fatal(_ code: ErrorCode, _ detail: String) {
        guard isAcceptingInput else { return }
        let error = WireError(code, debugDetail: detail)
        closeAllStreams(.connectionClosedLocally(error), keepPendingResets: false)
        dropAllQueues()
        enterClosing(error, drainsQueue: false)
    }

    mutating func enterClosing(_ error: WireError, drainsQueue: Bool) {
        closeError = error
        closeDrainsQueue = drainsQueue
        state = .closing
        closingDeadline = clock.raw.advanced(by: policy.closingDeadline)
        unresponsiveDeadline = nil
        livenessCloseDeadline = nil
        helloDeadline = nil
        emit(.closed(.closedLocally(error)))
    }

    mutating func dropAllQueues() {
        sessionQueue.removeAll()
        for slot in sessionPayloads.indices { sessionPayloads[slot] = nil }
        pendingConnectionWindow = 0
        pingPending = false
        for index in streams.indices {
            discardQueue(at: index)
            streams[index].pendingReset = nil
            streams[index].pendingWindow = 0
        }
        streams.removeAll { $0.isRetired }
    }

    mutating func finish() {
        state = .finished
        closingDeadline = nil
        unresponsiveDeadline = nil
        livenessCloseDeadline = nil
        helloDeadline = nil
        streams.removeAll()
    }
}
