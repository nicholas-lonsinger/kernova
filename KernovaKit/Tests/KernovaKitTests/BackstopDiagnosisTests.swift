import Foundation
import Testing

@testable import KernovaTestSupport

@Suite("Backstop self-diagnosis")
struct BackstopDiagnosisTests {
    @Test("an on-time, unsuspended backstop reports its numbers without a machine-state warning")
    func onTimeBackstop() {
        let text = backstopDiagnosis(timeout: 60, continuousElapsed: 60.25, uptimeElapsed: 60.25)
        #expect(text.contains("0.25 s past its deadline"))
        #expect(text.contains("0.00 s of it process-suspended"))
        #expect(!text.contains("machine state"))
    }

    @Test("a backstop far past its deadline warns of timer throttling even unsuspended")
    func lateUnsuspendedBackstop() {
        let text = backstopDiagnosis(timeout: 60, continuousElapsed: 126.70, uptimeElapsed: 126.70)
        #expect(text.contains("66.70 s past its deadline"))
        #expect(text.contains("suspect machine state"))
    }

    @Test("continuous-vs-uptime divergence reports suspension and warns even when barely late")
    func suspendedBackstop() {
        let text = backstopDiagnosis(timeout: 60, continuousElapsed: 61, uptimeElapsed: 2)
        #expect(text.contains("59.00 s of it process-suspended"))
        #expect(text.contains("suspect machine state"))
    }

    @Test("uptime elapsed exceeding continuous elapsed clamps suspension to zero")
    func clockGranularityJitter() {
        let text = backstopDiagnosis(timeout: 60, continuousElapsed: 60.5, uptimeElapsed: 60.6)
        #expect(text.contains("0.00 s of it process-suspended"))
        #expect(!text.contains("suspect machine state"))
    }
}
