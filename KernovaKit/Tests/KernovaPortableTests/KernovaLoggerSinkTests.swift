import KernovaLogging
import KernovaSynchronization
import Testing

#if canImport(os)
import OSLog
#endif

/// What `KernovaLogger.log(_:_:)` does in a process whose sink is never
/// bootstrapped: forwards to a logger's own sink, or builds the message only
/// when the local log records it.
@Suite("KernovaLogger's own sink")
struct KernovaLoggerSinkTests {
    private struct Record: Equatable {
        let level: KernovaLogLevel
        let subsystem: String
        let category: String
        let segments: [LogSegment]
    }

    @Test("log forwards to the logger's own sink, labelled with the logger's subsystem and category")
    func forwardsToTheLoggersOwnSink() {
        let records = Locked<[Record]>([])
        let logger = KernovaLogger(subsystem: "app.kernova.tests", category: "Sink") {
            level, subsystem, category, segments in
            records.withLock {
                $0.append(Record(level: level, subsystem: subsystem, category: category, segments: segments))
            }
        }
        let count = 3

        logger.log(.notice, "saw \(count, privacy: .public) items")

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

    @Test("A debug message reaches the sink whether or not the unified log records debug")
    func debugReachesTheSink() {
        let records = Locked<[Record]>([])
        let logger = KernovaLogger(subsystem: "app.kernova.tests", category: "Debug") {
            level, subsystem, category, segments in
            records.withLock {
                $0.append(Record(level: level, subsystem: subsystem, category: category, segments: segments))
            }
        }
        let path = "/tmp/x"

        logger.log(.debug, "opened \(path)")

        #expect(
            records.withLock { $0 } == [
                Record(
                    level: .debug, subsystem: "app.kernova.tests", category: "Debug",
                    segments: [
                        LogSegment(text: "opened ", isPrivate: false),
                        LogSegment(text: "/tmp/x", isPrivate: true),
                    ])
            ])
    }

    #if canImport(os)
    @Test("A message is built only when the unified log records its level, absent a sink")
    func messageWithoutASinkIsBuiltOnlyWhenRecorded() {
        let evaluations = Locked(0)
        func counted() -> Int {
            evaluations.withLock { $0 += 1 }
            return 0
        }
        let logger = KernovaLogger(subsystem: "app.kernova.tests", category: "Unsunk")

        logger.log(.debug, "value \(counted(), privacy: .public)")

        let recorded = OSLog(subsystem: "app.kernova.tests", category: "Unsunk").isEnabled(type: .debug)
        #expect(evaluations.withLock { $0 } == (recorded ? 1 : 0))
    }
    #else
    @Test("Absent a sink, a message below info is never built, and one at info is built once")
    func messageWithoutASinkIsBuiltOnlyAtTheThreshold() {
        let evaluations = Locked(0)
        func counted() -> Int {
            evaluations.withLock { $0 += 1 }
            return 0
        }
        let logger = KernovaLogger(subsystem: "app.kernova.tests", category: "Unsunk")

        logger.log(.debug, "value \(counted(), privacy: .public)")
        #expect(evaluations.withLock { $0 } == 0)

        logger.log(.info, "value \(counted(), privacy: .public)")
        #expect(evaluations.withLock { $0 } == 1)
    }
    #endif

    @Test("A message forwarded to a sink is built exactly once")
    func messageWithASinkIsBuiltOnce() {
        let evaluations = Locked(0)
        func counted() -> Int {
            evaluations.withLock { $0 += 1 }
            return 0
        }
        let logger = KernovaLogger(subsystem: "app.kernova.tests", category: "Once") { _, _, _, _ in }

        logger.log(.debug, "value \(counted(), privacy: .public)")

        #expect(evaluations.withLock { $0 } == 1)
    }
}
