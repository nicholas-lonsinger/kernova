import KernovaLogging
import Synchronization

/// Every record its `sink` receives — the sink a test builds the logger of the
/// component under test with.
final class LogCapture: Sendable {
    /// One record: its level and its message as written.
    struct Record: Equatable {
        let level: KernovaLogLevel
        let message: String
    }

    private let recorded = Mutex<[Record]>([])

    /// The sink whose records land here.
    var sink: KernovaLogger.ForwardingSink {
        { [self] level, _, _, segments in
            recorded.withLock {
                $0.append(Record(level: level, message: segments.map(\.text).joined()))
            }
        }
    }

    /// Every record so far, oldest first.
    var records: [Record] { recorded.withLock { $0 } }

    /// Every record's message, oldest first.
    var messages: [String] { records.map(\.message) }
}
