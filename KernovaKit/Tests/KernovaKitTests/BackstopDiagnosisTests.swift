import Foundation
import Testing

@testable import KernovaTestSupport

@Suite("Backstop self-diagnosis")
struct BackstopDiagnosisTests {
    @Test("an on-time backstop with no system sleep reports its numbers without a machine-state warning")
    func onTimeBackstop() {
        let text = backstopDiagnosis(timeout: 60, continuousElapsed: 60.25, uptimeElapsed: 60.25)
        #expect(text.contains("0.25 s past its deadline"))
        #expect(text.contains("the system slept 0.00 s"))
        #expect(!text.contains("machine state"))
    }

    @Test("a backstop far past its deadline warns of machine state even without system sleep")
    func lateUnsleptBackstop() {
        let text = backstopDiagnosis(timeout: 60, continuousElapsed: 126.70, uptimeElapsed: 126.70)
        #expect(text.contains("66.70 s past its deadline"))
        #expect(text.contains("suspect machine state"))
    }

    @Test("continuous-vs-uptime divergence reports system sleep and warns even when barely late")
    func systemSleepBackstop() {
        let text = backstopDiagnosis(timeout: 60, continuousElapsed: 61, uptimeElapsed: 2)
        #expect(text.contains("the system slept 59.00 s of the wait"))
        #expect(text.contains("suspect machine state"))
    }

    @Test("uptime elapsed exceeding continuous elapsed clamps the sleep figure to zero")
    func clockGranularityJitter() {
        let text = backstopDiagnosis(timeout: 60, continuousElapsed: 60.5, uptimeElapsed: 60.6)
        #expect(text.contains("the system slept 0.00 s"))
        #expect(!text.contains("suspect machine state"))
    }

    @Test("elapsed short of the timeout renders nothing — the backstop never fired")
    func flappedPredicate() {
        let text = backstopDiagnosis(timeout: 60, continuousElapsed: 0.15, uptimeElapsed: 0.15)
        #expect(text.isEmpty)
    }
}
