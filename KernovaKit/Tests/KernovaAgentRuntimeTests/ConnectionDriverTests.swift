#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaWire
import Testing

/// The driver's rules, over a scripted stream and a hand-run clock: every turn is one input, and the test
/// waits only for the driver queue to drain.
@Suite("Connection driver")
struct ConnectionDriverTests {
    private static let available = PeerInput.power(
        .availability(.available(PowerOffer(actions: [.shutdown, .restart]))))

    @Test("An input and a close sent before start() run after the stream starts, as the hub sends a new connection")
    func sentBeforeStartRunsAfterIt() async throws {
        let harness = PeerDriverHarness()
        harness.driver.handle(Self.available)
        harness.driver.close(.shuttingDown)
        harness.driver.start()
        try await harness.settle()
        #expect(harness.journal.take().prefix(2) == ["start", "arm"])
        #expect(harness.stream.writeCount == 1)
    }
}
