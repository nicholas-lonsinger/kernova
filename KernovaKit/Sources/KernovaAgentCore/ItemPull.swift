#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// The serving side of ITEM_PULL: checks the pull against this side's open offers, then sends exactly the
/// container its source produces, a read at a time, and ENDs once the source reports it finished. Each read
/// is a reservation of the connection's raw budget, so however many pulls are served at once, an answer
/// within its read always fits; the connection refuses a puller's END that precedes this side's
/// (`acceptorEndsFirst`). A pull exists from its `.serve` to its stream's close, which alone emits its
/// `.release` and its one `.serveEnded`.
struct ItemPullServer: Sendable {
    private struct Pull: Sendable {
        var id: ItemPullID
        var token: Data
        /// The bytes the outstanding read reserved, the most it may return; nil when none is outstanding.
        var granted: Int?
        /// The source finished and this side's END is queued.
        var ended = false
    }

    private var pulls: [Pull] = []

    /// The far side opened a pull: serve it when it names a representation of an open offer, RESET otherwise.
    mutating func opened(
        _ id: ItemPullID, body: Data, offers: ItemOfferRegistry, connection: inout Connection,
        outbox: inout [ItemTransferOutput]
    ) {
        let request = (try? PullRequest(serializedBytes: body)) ?? PullRequest()
        switch offers.localRepresentation(request) {
        case .failure(let error):
            connection.reset(id.stream, error)
        case .success(let representation):
            pulls.append(Pull(id: id, token: request.token))
            outbox.append(.source(.serve(id, request, representation)))
            serve(id.stream, connection: &connection, outbox: &outbox)
        }
    }

    /// Asks the source for the next read once the stream can take a worthwhile one.
    mutating func serve(_ stream: StreamID, connection: inout Connection, outbox: inout [ItemTransferOutput]) {
        guard let index = pulls.firstIndex(where: { $0.id.stream == stream }), !pulls[index].ended,
            pulls[index].granted == nil, connection.canQueue(on: stream)
        else { return }
        guard connection.writableData(stream) >= Limits.writableLowWater else { return }
        let grant = connection.reserveRawData(WireConstants.maxRawDataPayload, on: stream)
        pulls[index].granted = grant
        outbox.append(.source(.read(pulls[index].id, maxBytes: grant)))
    }

    /// The source's answer to the outstanding read. Bytes no read asked for, more than it granted, or none
    /// at all are the source's fault: the pull is RESET `READ_FAILED` rather than sent short or long.
    mutating func handle(
        _ input: ItemSourceInput, generation: ConnectionGeneration, connection: inout Connection,
        outbox: inout [ItemTransferOutput], diagnostics: inout [Diagnostic]
    ) {
        switch input {
        case .bytes(let id, let data):
            guard let index = index(id, generation), !pulls[index].ended, connection.canQueue(on: id.stream) else {
                return
            }
            guard let granted = pulls[index].granted else {
                return sourceFailed(
                    id, "the item source sent \(data.count) bytes no read asked for", &connection, &diagnostics)
            }
            pulls[index].granted = nil
            guard !data.isEmpty, data.count <= granted else {
                return sourceFailed(
                    id, "the item source returned \(data.count) bytes for a \(granted)-byte read", &connection,
                    &diagnostics)
            }
            connection.send(reserved: data, on: id.stream)
            serve(id.stream, connection: &connection, outbox: &outbox)
        case .finished(let id):
            guard let index = index(id, generation), !pulls[index].ended, connection.canQueue(on: id.stream) else {
                return
            }
            guard pulls[index].granted != nil else {
                return sourceFailed(id, "the item source finished with no read outstanding", &connection, &diagnostics)
            }
            pulls[index].granted = nil
            pulls[index].ended = true
            connection.releaseReservation(on: id.stream)
            connection.end(id.stream, body: Data())
        case .failed(let id, let error):
            guard let index = index(id, generation), !pulls[index].ended, connection.canReset(id.stream) else {
                return
            }
            connection.reset(id.stream, error)
        }
    }

    /// The registry changed: a pull of an offer no longer open is stale.
    mutating func offersChanged(_ offers: ItemOfferRegistry, connection: inout Connection) {
        let open = offers.localTokens
        for pull in pulls where !open.contains(pull.token) && connection.canReset(pull.id.stream) {
            connection.reset(pull.id.stream, WireError(.itemOfferStale))
        }
    }

    mutating func closed(_ stream: StreamID, _ closure: StreamClosure, outbox: inout [ItemTransferOutput]) {
        guard let index = pulls.firstIndex(where: { $0.id.stream == stream }) else { return }
        let id = pulls.remove(at: index).id
        outbox.append(.source(.release(id)))
        outbox.append(.event(.serveEnded(id, Self.result(closure))))
    }

    /// The puller's `PullOutcome` when it ENDed; otherwise how the stream closed.
    private static func result(_ closure: StreamClosure) -> ItemPullResult {
        guard case .completed(let body) = closure else { return .closed(closure) }
        guard let outcome = try? Kernova_V2_PullOutcome(serializedBytes: body) else {
            return .failed(WireError(.malformedMessage, debugDetail: "a PullOutcome that does not decode"))
        }
        return outcome.kind == .landed ? .landed : .failed(WireError(received: outcome.error))
    }

    private func index(_ id: ItemPullID, _ generation: ConnectionGeneration) -> Int? {
        guard id.generation == generation else { return nil }
        return pulls.firstIndex { $0.id == id }
    }

    private func sourceFailed(
        _ id: ItemPullID, _ detail: String, _ connection: inout Connection, _ diagnostics: inout [Diagnostic]
    ) {
        diagnostics.append(.localFault(detail))
        if connection.canReset(id.stream) { connection.reset(id.stream, WireError(.readFailed, debugDetail: detail)) }
    }
}

/// The pulling side of ITEM_PULL: opens a pull of the far side's open offer, hands the container's bytes to
/// its sink as they arrive, asks it to finish at the far side's END, and ENDs with the sink's verdict as a
/// `PullOutcome`; a verified container is committed at once. A sink refusal before the END RESETs the pull
/// with the sink's code, and so does the end of the offer it names, with `ITEM_OFFER_STALE`. A pull exists
/// from the `.success` `pull` returns to its stream's close, which alone emits its one `.pullEnded`, after the
/// sink's `.abort` unless it was told to commit.
struct ItemPullClient: Sendable {
    private enum Sink: Sendable, Equatable {
        /// Container bytes are arriving.
        case receiving
        /// The far side ended; the sink was asked to finish.
        case finishing
        /// The sink verified the container and was told to commit it.
        case committed
        /// The sink refused it.
        case refused(WireError)
    }

    private struct Pull: Sendable {
        var id: ItemPullID
        var token: Data
        var sink: Sink = .receiving
    }

    private var pulls: [Pull] = []

    mutating func pull(
        _ request: PullRequest, offers: ItemOfferRegistry, generation: ConnectionGeneration,
        connection: inout Connection, outbox: inout [ItemTransferOutput]
    ) -> Result<ItemPullID, WireError> {
        let representation: Representation
        switch offers.remoteRepresentation(request) {
        case .failure(let error): return .failure(error)
        case .success(let named): representation = named
        }
        let kind: StreamKind = connection.role == .host ? .itemPullByHost : .itemPullByPeer
        if let refusal = connection.openRefusal(kind) { return .failure(refusal) }
        let stream = connection.open(kind, body: request.encoded)
        guard stream != .session else { return .failure(WireError(.internal, debugDetail: "the open failed")) }
        let id = ItemPullID(generation: generation, stream: stream)
        pulls.append(Pull(id: id, token: request.token))
        outbox.append(.sink(.begin(id, request, representation)))
        return .success(id)
    }

    /// The registry changed: a pull of an offer no longer open ends `ITEM_OFFER_STALE`, uncommitted.
    mutating func offersChanged(_ offers: ItemOfferRegistry, connection: inout Connection) {
        let open = offers.remoteTokens
        for pull in pulls
        where !open.contains(pull.token) && pull.sink != .committed
            && connection.canReset(pull.id.stream)
        {
            connection.reset(pull.id.stream, WireError(.itemOfferStale))
        }
    }

    mutating func cancel(_ stream: StreamID, connection: inout Connection) {
        guard pulls.contains(where: { $0.id.stream == stream }), connection.canReset(stream) else { return }
        connection.reset(stream, WireError(.cancelled))
    }

    mutating func data(_ stream: StreamID, _ bytes: Data, outbox: inout [ItemTransferOutput]) {
        guard let pull = pulls.first(where: { $0.id.stream == stream }), pull.sink == .receiving else { return }
        outbox.append(.sink(.bytes(pull.id, bytes)))
    }

    mutating func remoteEnded(_ stream: StreamID, outbox: inout [ItemTransferOutput]) {
        guard let index = pulls.firstIndex(where: { $0.id.stream == stream }), pulls[index].sink == .receiving else {
            return
        }
        pulls[index].sink = .finishing
        outbox.append(.sink(.finish(pulls[index].id)))
    }

    mutating func handle(
        _ input: ItemSinkInput, generation: ConnectionGeneration, connection: inout Connection,
        outbox: inout [ItemTransferOutput], diagnostics: inout [Diagnostic]
    ) {
        switch input {
        case .consumed(let id, let count):
            guard index(id, generation) != nil else { return }
            connection.consumed(count, on: id.stream)
        case .verified(let id):
            guard let index = index(id, generation) else { return }
            guard pulls[index].sink == .finishing else {
                return diagnostics.append(.localFault("the item sink verified a pull it was not asked to finish"))
            }
            pulls[index].sink = .committed
            outbox.append(.sink(.commit(id)))
            end(id.stream, Self.outcome(nil), &connection)
        case .refused(let id, let error):
            guard let index = index(id, generation) else { return }
            switch pulls[index].sink {
            case .receiving:
                pulls[index].sink = .refused(error)
                if connection.canReset(id.stream) { connection.reset(id.stream, error) }
            case .finishing:
                pulls[index].sink = .refused(error)
                end(id.stream, Self.outcome(error), &connection)
            case .committed, .refused:
                diagnostics.append(.localFault("the item sink refused a pull it already settled"))
            }
        }
    }

    mutating func closed(_ stream: StreamID, _ closure: StreamClosure, outbox: inout [ItemTransferOutput]) {
        guard let index = pulls.firstIndex(where: { $0.id.stream == stream }) else { return }
        let pull = pulls.remove(at: index)
        let result: ItemPullResult
        switch pull.sink {
        case .committed:
            result = .landed
        case .refused(let error):
            outbox.append(.sink(.abort(pull.id)))
            result = .failed(error)
        case .receiving, .finishing:
            outbox.append(.sink(.abort(pull.id)))
            result = .closed(closure)
        }
        outbox.append(.event(.pullEnded(pull.id, result)))
    }

    private func index(_ id: ItemPullID, _ generation: ConnectionGeneration) -> Int? {
        guard id.generation == generation else { return nil }
        return pulls.firstIndex { $0.id == id }
    }

    private func end(_ stream: StreamID, _ outcome: Data, _ connection: inout Connection) {
        guard connection.canQueue(on: stream) else { return }
        connection.end(stream, body: outcome)
    }

    /// A `PullOutcome`: LANDED, or FAILED with `error`.
    private static func outcome(_ error: WireError?) -> Data {
        var outcome = Kernova_V2_PullOutcome()
        outcome.kind = error == nil ? .landed : .failed
        if let error { outcome.error = error.proto }
        return outcome.encoded
    }
}
