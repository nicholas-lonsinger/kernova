import Testing
import Foundation
@testable import KernovaKit

@Suite("ControlChannelCadence")
struct ControlChannelCadenceTests {
    @Test("Production cadence keeps the unresponsive stage ahead of terminate")
    func productionOrdersItsStages() {
        let cadence = ControlChannelCadence.production
        #expect(cadence.heartbeatInterval == 5)
        #expect(cadence.unresponsiveAfter == 15)
        #expect(cadence.terminateAfter == 30)
    }

    @Test("Liveness ticks several times per unresponsive window")
    func tickDividesTheUnresponsiveWindow() {
        // unresponsiveAfter / 3 is the smaller of the two.
        let cadence = ControlChannelCadence(
            heartbeatInterval: 5, unresponsiveAfter: 6, terminateAfter: 30)
        #expect(cadence.livenessTickInterval == 2)
    }

    @Test("Liveness ticks no faster than the heartbeat interval")
    func tickIsCappedAtTheHeartbeat() {
        // heartbeatInterval is the smaller of the two.
        let cadence = ControlChannelCadence(
            heartbeatInterval: 5, unresponsiveAfter: 60, terminateAfter: 120)
        #expect(cadence.livenessTickInterval == 5)
    }

    @Test("Production derives its tick from the heartbeat cap")
    func productionTickFollowsTheHeartbeat() {
        #expect(ControlChannelCadence.production.livenessTickInterval == 5)
    }
}
