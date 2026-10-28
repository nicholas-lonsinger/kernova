#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// One direction of a link's transport.
package struct PipeParameters: Sendable {
    /// Bytes in flight before the writer waits (the VZ stall observation).
    package var capacity = 1 << 20
    /// Serialization rate.
    package var bytesPerSecond: UInt64
    /// One-way latency.
    package var latency: SimTime = .us(100)
    /// The largest read the reader takes.
    package var maxRead = 65_536

    package static let hostToGuest = PipeParameters(bytesPerSecond: 6_871_947_673)
    package static let guestToHost = PipeParameters(bytesPerSecond: 786_432_000)
}

/// The bytes one side wrote and the other has not yet read.
final class SimPipe {
    let parameters: PipeParameters
    private var segments: [(at: SimTime, data: Data)] = []
    private var head = 0
    private var offsetInHead = 0
    private(set) var inFlight = 0
    var writePending = false
    var readScheduled = false
    /// Deliver exactly this many bytes, then end the transport both ways.
    var cutAfter: Int?
    private(set) var accepted = 0
    private(set) var delivered = 0
    /// The writer shut down: the reader sees EOF once the pipe is empty.
    var writerClosed = false
    /// The reader shut down: the writer's next write fails.
    var readerClosed = false
    var eofDelivered = false
    var stalledUntil: SimTime?
    /// When the last accepted byte finishes serializing.
    private var busyUntil: SimTime = 0

    init(_ parameters: PipeParameters) {
        self.parameters = parameters
    }

    var hasCapacity: Bool { inFlight < parameters.capacity }
    var isCut: Bool { cutAfter.map { accepted >= $0 } ?? false }
    var isEmpty: Bool { head >= segments.count }

    /// Accepts a write at `now`; returns when it completes and how many bytes went in.
    func write(_ data: Data, now: SimTime) -> (completesAt: SimTime, accepted: Int) {
        var data = data
        if let cutAfter {
            let room = max(0, cutAfter - accepted)
            if data.count > room { data = data.prefix(room) }
        }
        let start = max(now, busyUntil)
        let serialization = SimTime(UInt64(data.count) * 1_000_000_000 / parameters.bytesPerSecond)
        busyUntil = start + serialization
        if !data.isEmpty {
            segments.append((at: busyUntil + parameters.latency, data: data))
            inFlight += data.count
            accepted += data.count
        }
        return (busyUntil, data.count)
    }

    /// When the next byte is readable, if any is in flight.
    var nextReadable: SimTime? { isEmpty ? nil : segments[head].at }

    /// Takes up to `count` bytes readable at `now`.
    func read(upTo count: Int, now: SimTime) -> Data {
        var out = Data()
        while out.count < count, head < segments.count, segments[head].at <= now {
            let segment = segments[head].data
            let start = segment.startIndex + offsetInHead
            let take = min(count - out.count, segment.endIndex - start)
            out.append(segment[start..<(start + take)])
            offsetInHead += take
            if offsetInHead == segment.count {
                segments[head].data = Data()
                head += 1
                offsetInHead = 0
            }
        }
        if head == segments.count {
            segments.removeAll(keepingCapacity: true)
            head = 0
        }
        inFlight -= out.count
        delivered += out.count
        return out
    }

    /// Whether the reader should now see the transport end.
    var readerShouldEnd: Bool {
        guard isEmpty, !eofDelivered else { return false }
        return writerClosed || isCut
    }
}
