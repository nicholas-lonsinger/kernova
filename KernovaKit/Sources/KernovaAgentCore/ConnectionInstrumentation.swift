#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

#if DEBUG
/// A connection's current memory and credit, for the simulation's bounds and
/// conservation checks.
package struct MemoryFootprint: Sendable, Equatable {
    /// Raw DATA delivered to machines and not yet consumed.
    package var heldRawBytes: Int
    /// Bytes the decoder holds.
    package var decoderBufferedBytes: Int
    /// Raw DATA queued and not yet handed out.
    package var queuedRawBytes: Int
    /// The most MESSAGE frames queued on any one stream.
    package var maxQueuedMessagesPerStream: Int
    /// Pending control frames: session snapshots, WINDOWs, PING, stream RESETs.
    package var controlFrames: Int
    /// Events not yet polled.
    package var pendingEvents: Int
    /// Streams in the table, refused ones awaiting their RESET included.
    package var streamRecords: Int
    /// Credit this side may still spend sending raw DATA.
    package var connectionSendCredit: Int
    /// Raw DATA the far side may still send this side.
    package var connectionReceiveRemaining: Int
    /// Connection credit owed back to the far side, a queued WINDOW included.
    package var unreturnedConnectionCredit: Int
}

/// What the simulation reads of a connection beside its events.
package enum ConnectionTrace: Sendable, Equatable {
    case localOpened(StreamID, StreamKind)
    case sent(StreamID, isMessage: Bool, Data)
    case event(ConnectionEvent)
}

extension Connection {
    /// The connection's memory and credit now.
    package var footprintForTesting: MemoryFootprint {
        var control = sessionQueue.count + (pendingConnectionWindow > 0 ? 1 : 0) + (pingPending ? 1 : 0)
        var maxMessages = 0
        for record in streams {
            control += (record.pendingReset != nil ? 1 : 0) + (record.pendingWindow > 0 ? 1 : 0)
            maxMessages = max(maxMessages, record.unsentMessages)
        }
        return MemoryFootprint(
            heldRawBytes: connectionHeldRaw, decoderBufferedBytes: decoder.bufferedByteCountForTesting,
            queuedRawBytes: queuedRawTotal, maxQueuedMessagesPerStream: maxMessages, controlFrames: control,
            pendingEvents: events.count - eventHead, streamRecords: streams.count,
            connectionSendCredit: connectionSendCredit, connectionReceiveRemaining: connectionReceiveRemaining,
            unreturnedConnectionCredit: connectionUnreturned + pendingConnectionWindow)
    }

    /// Takes the trace the simulation reads, emptying it.
    package mutating func takeTraceForTesting() -> [ConnectionTrace] {
        defer { trace.removeAll(keepingCapacity: true) }
        return trace
    }

    /// Appends `entry` to the trace when the configuration records one.
    mutating func appendTrace(_ entry: ConnectionTrace) {
        if configuration.recordsTraceForTesting { trace.append(entry) }
    }
}
#endif
