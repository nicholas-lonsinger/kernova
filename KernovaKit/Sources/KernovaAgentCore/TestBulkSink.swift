#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// The simulation's machine for the bulk test kinds: the acceptor sends
/// a configured number of raw bytes as credit allows, then END; the opener
/// consumes them, or holds them unconsumed while stalled, and ENDs back.
package struct TestBulkSink: Sendable {
    package struct Flow: Sendable, Equatable {
        package var stream: StreamID
        package var kind: StreamKind
        package var isSender: Bool
        package var remaining: Int
        package var delivered = 0
        package var held = 0
        package var consumes: Bool
    }

    package private(set) var flows: [Flow] = []
    /// Bytes an accepted stream sends before its END; negative sends nothing and never ends.
    package var bytesPerStream = 0
    /// Whether newly opened receiving flows consume what they get.
    package var consumesByDefault = true

    package init() {}

    package mutating func open(
        _ kind: StreamKind, consumes: Bool, connection: inout Connection
    ) -> StreamID? {
        guard connection.canOpen(kind) else { return nil }
        let stream = connection.open(kind, body: Data())
        flows.append(Flow(stream: stream, kind: kind, isSender: false, remaining: 0, consumes: consumes))
        return stream
    }

    /// Resets `stream` with CANCELLED.
    package mutating func reset(_ stream: StreamID, connection: inout Connection) {
        guard connection.canReset(stream) else { return }
        connection.reset(stream, WireError(.cancelled))
    }

    /// Starts or stops consuming on `stream`; resuming consumes what is held.
    package mutating func setConsumes(_ consumes: Bool, on stream: StreamID, connection: inout Connection) {
        guard let index = flows.firstIndex(where: { $0.stream == stream }) else { return }
        flows[index].consumes = consumes
        if consumes, flows[index].held > 0 {
            connection.consumed(flows[index].held, on: stream)
            flows[index].held = 0
        }
    }

    package mutating func handle(_ event: FeatureEvent, connection: inout Connection) {
        switch event {
        case .opened(let stream, _):
            let kind: StreamKind = stream.rawValue % 2 == 1 ? .UNRECOGNIZED(9000) : .UNRECOGNIZED(9001)
            flows.append(Flow(stream: stream, kind: kind, isSender: true, remaining: bytesPerStream, consumes: true))
            pump(stream, &connection)
        case .writable(let stream):
            pump(stream, &connection)
        case .data(let stream, let bytes):
            guard let index = flows.firstIndex(where: { $0.stream == stream }) else { return }
            flows[index].delivered += bytes.count
            if flows[index].consumes {
                connection.consumed(bytes.count, on: stream)
            } else {
                flows[index].held += bytes.count
            }
        case .remoteEnded(let stream, _):
            if connection.canQueue(on: stream) { connection.end(stream, body: Data()) }
        case .streamClosed(let stream, _):
            flows.removeAll { $0.stream == stream }
        case .sessionEstablished, .usabilityChanged, .policyChanged, .message, .deadline:
            break
        }
    }

    private mutating func pump(_ stream: StreamID, _ connection: inout Connection) {
        guard let index = flows.firstIndex(where: { $0.stream == stream }), flows[index].isSender,
            flows[index].remaining >= 0 || bytesPerStream >= 0
        else { return }
        while flows[index].remaining > 0, connection.canQueue(on: stream) {
            let count = min(flows[index].remaining, connection.writableData(stream), WireConstants.maxRawDataPayload)
            guard count > 0 else { return }
            connection.send(
                data: Data(repeating: UInt8(truncatingIfNeeded: flows[index].remaining), count: count), on: stream)
            flows[index].remaining -= count
            flows[index].delivered += count
        }
        if flows[index].remaining == 0, connection.canQueue(on: stream),
            connection.phase(of: stream) == .open || connection.phase(of: stream) == .remoteEnded
        {
            connection.end(stream, body: Data())
            flows[index].remaining = -1
        }
    }
}
