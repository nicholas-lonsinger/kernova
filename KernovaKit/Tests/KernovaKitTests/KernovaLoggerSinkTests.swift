import KernovaLogging
import KernovaSynchronization
import KernovaTestSupport
import Testing

@Suite("KernovaLogger's own sink", .caseScoped)
struct KernovaLoggerSinkTests {
    private struct Record: Equatable {
        let level: KernovaLogLevel
        let subsystem: String
        let category: String
        let segments: [LogSegment]
    }

    @Test("#log forwards to the logger's own sink, labelled with the logger's subsystem and category")
    func forwardsToTheLoggersOwnSink() {
        let records = Locked<[Record]>([])
        let logger = KernovaLogger(subsystem: "app.kernova.tests", category: "Sink") {
            level, subsystem, category, segments in
            records.withLock {
                $0.append(Record(level: level, subsystem: subsystem, category: category, segments: segments))
            }
        }
        let count = 3

        #log(logger, .notice, "saw \(count, privacy: .public) items")

        #expect(
            records.withLock { $0 } == [
                Record(
                    level: .notice, subsystem: "app.kernova.tests", category: "Sink",
                    segments: [
                        LogSegment(text: "saw ", isPrivate: false),
                        LogSegment(text: "3", isPrivate: false),
                        LogSegment(text: " items", isPrivate: false),
                    ])
            ])
    }
}
