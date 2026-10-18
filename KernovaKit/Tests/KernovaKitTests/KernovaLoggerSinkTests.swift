import Foundation
import KernovaLogging
import KernovaSynchronization
import KernovaTestSupport
import Testing

/// Where `#log` forwards: a logger's own sink, or else the process sink.
///
/// The process sink is bootstrapped once per process, so each test that
/// bootstraps it runs as an exit test in a process of its own, and its sinks
/// report by the code they exit with.
@Suite("KernovaLogger's own sink and the process sink", .caseScoped)
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

    @Test("A second bootstrap of the process sink stops the process")
    func secondBootstrapTraps() async {
        await #expect(processExitsWith: .failure) {
            KernovaLogger.bootstrapProcessSink { _, _, _, _ in }
            KernovaLogger.bootstrapProcessSink { _, _, _, _ in }
        }
    }

    @Test("A logger with no sink of its own forwards to the process sink")
    func loggerWithoutASinkReachesTheProcessSink() async {
        await #expect(processExitsWith: .exitCode(42)) {
            KernovaLogger.bootstrapProcessSink { level, subsystem, category, segments in
                let expected = [LogSegment(text: "to the process", isPrivate: false)]
                let matches =
                    level == .notice && subsystem == "app.kernova.tests" && category == "Process"
                    && segments == expected
                exit(matches ? 42 : 43)
            }
            let logger = KernovaLogger(subsystem: "app.kernova.tests", category: "Process")
            #log(logger, .notice, "to the process")
        }
    }

    @Test("A logger's own sink takes precedence over the process sink")
    func ownSinkTakesPrecedence() async {
        await #expect(processExitsWith: .exitCode(7)) {
            KernovaLogger.bootstrapProcessSink { _, _, _, _ in exit(42) }
            let logger = KernovaLogger(subsystem: "app.kernova.tests", category: "Own") { _, _, _, _ in
                exit(7)
            }
            #log(logger, .notice, "to its own sink")
        }
    }
}
