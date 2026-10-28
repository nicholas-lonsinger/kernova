#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// A forwarded record's level, mapped one-to-one onto the host's.
public enum LogLevelValue: Int, Sendable, Equatable {
    /// Republished at notice.
    case unspecified = 0
    /// Debug.
    case debug = 1
    /// Info.
    case info = 2
    /// Notice.
    case notice = 3
    /// Warning.
    case warning = 4
    /// Error.
    case error = 5
    /// Fault.
    case fault = 6
}

/// One run of a record's message, with its privacy.
public struct LogSegmentValue: Sendable, Equatable {
    /// The run's text.
    public var text: String
    /// Whether the emitting side marked it private.
    public var isPrivate: Bool

    /// Creates a segment.
    public init(text: String, isPrivate: Bool = false) {
        self.text = text
        self.isPrivate = isPrivate
    }
}

/// One guest log record (§7.1), bounded when it is created.
public struct LogRecordValue: Sendable, Equatable {
    /// Subsystem and category: at most this many UTF-8 bytes each.
    public static let maxLabelBytes = 128
    /// At most this many segments.
    public static let maxSegments = 256
    /// Segment text: at most this many UTF-8 bytes in total.
    public static let maxTextBytes = 16_384

    /// Wall clock at emission, milliseconds since the Unix epoch.
    public var timestampMilliseconds: Int64
    /// The record's level.
    public var level: LogLevelValue
    /// An opaque subsystem label.
    public var subsystem: String
    /// An opaque category label.
    public var category: String
    /// The message's runs, in emission order.
    public var segments: [LogSegmentValue]
    /// A bound cut the record.
    public var truncated: Bool

    /// Creates a record, applying §7.1's bounds.
    public init(
        timestampMilliseconds: Int64, level: LogLevelValue, subsystem: String, category: String,
        segments: [LogSegmentValue], truncated: Bool = false
    ) {
        self.timestampMilliseconds = timestampMilliseconds
        self.level = level
        self.subsystem = Normalize.clip(subsystem, maxBytes: Self.maxLabelBytes)
        self.category = Normalize.clip(category, maxBytes: Self.maxLabelBytes)
        var cut = truncated || segments.count > Self.maxSegments
        var kept: [LogSegmentValue] = []
        var budget = Self.maxTextBytes
        for segment in segments.prefix(Self.maxSegments) {
            let bytes = segment.text.utf8.count
            if bytes <= budget {
                kept.append(segment)
                budget -= bytes
            } else {
                kept.append(
                    LogSegmentValue(text: Normalize.clip(segment.text, maxBytes: budget), isPrivate: segment.isPrivate))
                budget = 0
                cut = true
            }
        }
        self.segments = kept
        self.truncated = cut
    }

    var proto: Kernova_V2_LogRecord {
        var record = Kernova_V2_LogRecord()
        record.timestampMs = timestampMilliseconds
        record.level = Kernova_V2_LogLevel(rawValue: level.rawValue) ?? .unspecified
        record.subsystem = subsystem
        record.category = category
        record.segments = segments.map { segment in
            var proto = Kernova_V2_LogSegment()
            proto.text = segment.text
            proto.private = segment.isPrivate
            return proto
        }
        record.truncated = truncated
        return record
    }

    init(received record: Kernova_V2_LogRecord) {
        self.init(
            timestampMilliseconds: record.timestampMs,
            level: LogLevelValue(rawValue: record.level.rawValue) ?? .unspecified,
            subsystem: record.subsystem, category: record.category,
            segments: record.segments.map { LogSegmentValue(text: $0.text, isPrivate: $0.private) },
            truncated: record.truncated)
    }

    /// The record's size inside a `LogBatch`: its tag, its length prefix and its bytes.
    var batchEntryBytes: Int {
        let bytes = proto.encoded.count
        return 1 + Self.varintBytes(UInt64(bytes)) + bytes
    }

    static func varintBytes(_ value: UInt64) -> Int {
        var value = value
        var count = 1
        while value >= 0x80 {
            value >>= 7
            count += 1
        }
        return count
    }
}

/// One batch taken from the ring.
public struct LogBatchValue: Sendable, Equatable {
    /// The records, oldest first.
    public var records: [LogRecordValue]
    /// Records the ring evicted, unsent, just before `records[0]`.
    public var droppedBefore: UInt64

    /// Creates a batch.
    public init(records: [LogRecordValue], droppedBefore: UInt64) {
        self.records = records
        self.droppedBefore = droppedBefore
    }

    var encoded: Data {
        var batch = Kernova_V2_LogBatch()
        batch.records = records.map(\.proto)
        batch.droppedBefore = droppedBefore
        return batch.encoded
    }
}

/// What a peer's ring does with appends (§7.2).
public enum LogRingMode: Sendable, Equatable {
    /// Hold records until the host decides.
    case buffering
    /// Hold records for the forwarder.
    case forwarding
    /// Refuse appends; the ring and its count are empty.
    case discarding
}

/// The peer's process-wide ring between the logger and the wire (§7.2).
public struct LogRing: Sendable, Equatable {
    /// Records held at most.
    public static let capacity = 256
    /// A batch's record bound.
    public static let batchRecords = 64
    /// A batch's encoded bound, under the 64 KiB message limit.
    public static let batchBytes = 61_440

    private var records: [LogRecordValue] = []
    private var head = 0
    /// Records evicted since the last batch.
    public private(set) var droppedCount: UInt64 = 0
    /// What appends do.
    public private(set) var mode = LogRingMode.buffering

    /// An empty ring, buffering.
    public init() {}

    /// The records held.
    public var count: Int { records.count - head }

    /// Appends `record`, evicting the oldest when full; refused while discarding.
    /// True when the ring was empty before, which is when the sink posts
    /// `.logs(.recordsAvailable)`.
    @discardableResult
    public mutating func append(_ record: LogRecordValue) -> Bool {
        guard mode != .discarding else { return false }
        let wasEmpty = count == 0
        if count == Self.capacity {
            head += 1
            droppedCount += 1
        }
        records.append(record)
        if head >= Self.capacity {
            records.removeFirst(head)
            head = 0
        }
        return wasEmpty
    }

    /// Applies the forwarder's mode; discarding empties the ring and its count.
    public mutating func setMode(_ mode: LogRingMode) {
        self.mode = mode
        if mode == .discarding {
            records.removeAll()
            head = 0
            droppedCount = 0
        }
    }

    /// Removes up to `maxRecords` records, oldest first, within `maxEncodedBytes`
    /// of batch encoding; one record always fits. Nil when the ring holds none.
    public mutating func takeBatch(maxRecords: Int = batchRecords, maxEncodedBytes: Int = batchBytes)
        -> LogBatchValue?
    {
        guard count > 0 else { return nil }
        let dropped = droppedCount
        var used = 1 + LogRecordValue.varintBytes(dropped)
        var taken: [LogRecordValue] = []
        while head < records.count, taken.count < maxRecords {
            let size = records[head].batchEntryBytes
            guard taken.isEmpty || used + size <= maxEncodedBytes else { break }
            used += size
            taken.append(records[head])
            head += 1
        }
        if head == records.count {
            records.removeAll(keepingCapacity: true)
            head = 0
        }
        droppedCount = 0
        return LogBatchValue(records: taken, droppedBefore: dropped)
    }
}
