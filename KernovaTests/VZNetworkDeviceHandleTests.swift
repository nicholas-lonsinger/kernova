import Testing
@testable import Kernova

@Suite("VZNetworkDeviceHandle Tests", .admissionGated)
@MainActor
struct VZNetworkDeviceHandleTests {
    private struct Harness {
        let handle: VZNetworkDeviceHandle
        let install: MockNetworkAttachmentInstall
    }

    private func makeHarness(initialPlan: NetworkAttachmentPlan? = nil) -> Harness {
        let install = MockNetworkAttachmentInstall()
        return Harness(
            handle: VZNetworkDeviceHandle(
                session: install, initialPlan: initialPlan,
                vmnetNetworks: MockVmnetNetworkProvider()),
            install: install)
    }

    /// Runs behind the correction's main-actor hop, which the serial main
    /// executor enqueued ahead of this.
    private func drainCorrection() async {
        await Task { @MainActor in }.value
    }

    @Test("A build finding nothing at install time clears the applied mirror")
    func buildFoundNothingClearsMirror() async {
        let harness = makeHarness()
        #expect(harness.handle.apply(.nat))
        #expect(harness.handle.currentPlan == .nat)

        harness.install.reportBuildFoundNothing(ofApplyAt: 0)
        await drainCorrection()

        #expect(harness.handle.currentPlan == nil)
    }

    @Test("A build failure reported after a newer apply leaves that apply's plan")
    func staleBuildFailureLeavesNewerApply() async {
        let harness = makeHarness()
        #expect(harness.handle.apply(.nat))
        #expect(harness.handle.apply(.hostOnly))
        #expect(harness.install.applyCount == 2)

        harness.install.reportBuildFoundNothing(ofApplyAt: 0)
        await drainCorrection()

        #expect(harness.handle.currentPlan == .hostOnly)
    }

    @Test("Detach clears the mirror and forwards to the session")
    func detachClearsMirror() {
        let harness = makeHarness(initialPlan: .nat)
        #expect(harness.handle.currentPlan == .nat)

        harness.handle.detach()

        #expect(harness.handle.currentPlan == nil)
        #expect(harness.install.detachCount == 1)
    }
}
