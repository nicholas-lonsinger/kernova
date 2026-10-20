import Foundation
import KernovaLogging
import KernovaTestSupport
import Testing

/// Where `KernovaLogger.log(_:_:)` forwards once the process sink is
/// bootstrapped: a logger's own sink, or else the process sink.
///
/// The process sink is bootstrapped once per process, so each test runs as an
/// exit test in a process of its own, and its sinks report by the code they
/// exit with.
@Suite("KernovaLogger's process sink", .caseScoped)
struct KernovaLoggerProcessSinkTests {
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
            logger.log(.notice, "to the process")
        }
    }

    @Test("A logger's own sink takes precedence over the process sink")
    func ownSinkTakesPrecedence() async {
        await #expect(processExitsWith: .exitCode(7)) {
            KernovaLogger.bootstrapProcessSink { _, _, _, _ in exit(42) }
            let logger = KernovaLogger(subsystem: "app.kernova.tests", category: "Own") { _, _, _, _ in
                exit(7)
            }
            logger.log(.notice, "to its own sink")
        }
    }
}
