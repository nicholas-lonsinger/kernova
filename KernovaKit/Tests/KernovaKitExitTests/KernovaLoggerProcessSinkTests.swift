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
    @Test("The process sink runs at the same stack depth however many records came before it")
    func processSinkDepthStaysFlat() async {
        await #expect(processExitsWith: .exitCode(42)) {
            KernovaLogger.bootstrapProcessSink(
                .init { _, _, _, _ in
                    sinkDepths.append(Thread.callStackSymbols.count)
                })
            let logger = KernovaLogger(subsystem: "app.kernova.tests", category: "Depth")
            for _ in 0..<200 {
                logger.log(.notice, "one more record")
            }
            exit(sinkDepths.count == 200 && Set(sinkDepths).count == 1 ? 42 : 43)
        }
    }
}

/// The stack depth of each process-sink call in `processSinkDepthStaysFlat`'s
/// child process, which logs from its one thread.
nonisolated(unsafe) private var sinkDepths: [Int] = []
