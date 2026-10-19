import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaVirtualization
@testable import KernovaVirtualizationTestSupport

@Suite("VZNetworkDeviceHandle Tests", .caseScoped)
@MainActor
struct VZNetworkDeviceHandleTests {
    private struct Harness {
        let handle: VZNetworkDeviceHandle
        let install: MockNetworkAttachmentInstall
        let vmnet: ScriptedVmnetNetworks
        let owner: UUID
        let sessionNetworks: VmnetSessionNetworks
        let attachments: MockVmnetAttachments
    }

    private func makeHarness(initialPlan: NetworkAttachmentPlan? = nil) -> Harness {
        let install = MockNetworkAttachmentInstall()
        let vmnet = ScriptedVmnetNetworks()
        let owner = UUID()
        let sessionNetworks = vmnet.service.sessionNetworks(ownedBy: owner)
        let attachments = MockVmnetAttachments()
        // Up before any apply, so one onto it attaches straight away.
        vmnet.materialize(.common(.hostOnly), through: sessionNetworks)
        return Harness(
            handle: VZNetworkDeviceHandle(
                session: install, initialPlan: initialPlan, vmnetNetworks: sessionNetworks,
                vmnetAttachments: attachments.maker),
            install: install, vmnet: vmnet, owner: owner, sessionNetworks: sessionNetworks,
            attachments: attachments)
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
        #expect(harness.handle.apply(.vmnet(.common(.hostOnly))))
        #expect(harness.install.applyCount == 2)

        harness.install.reportBuildFoundNothing(ofApplyAt: 0)
        await drainCorrection()

        #expect(harness.handle.currentPlan == .vmnet(.common(.hostOnly)))
    }

    @Test("A queued vmnet build holds its network until it has built, and its attachment holds it after")
    func aQueuedBuildHoldsItsNetwork() throws {
        let harness = makeHarness()
        let operations = harness.vmnet.operations
        harness.vmnet.materialize(.own(.nat), through: harness.sessionNetworks)
        let ownNAT = try #require(harness.sessionNetworks.joinedNetworkIfMaterialized(for: .own(.nat))?.network)
        #expect(harness.handle.apply(.vmnet(.own(.nat))))

        // The own NAT network loses its only member.
        harness.vmnet.materialize(.own(.hostOnly), through: harness.sessionNetworks)
        #expect(operations.releasedNetworks.isEmpty)

        var attachment = autoreleasepool { harness.install.runBuild(ofApplyAt: 0) }
        #expect(attachment != nil)
        #expect(harness.attachments.madeNetworks == [ownNAT])
        #expect(operations.releasedNetworks.isEmpty)

        attachment = nil
        #expect(operations.releasedNetworks == [ownNAT])
    }

    @Test("A queued vmnet build leaves the VM on the network it joined since")
    func aQueuedBuildLeavesTheVMWhereItMoved() throws {
        let harness = makeHarness()
        #expect(harness.handle.apply(.vmnet(.common(.hostOnly))))

        harness.vmnet.materialize(.own(.nat), through: harness.sessionNetworks)
        let attachment = autoreleasepool { harness.install.runBuild(ofApplyAt: 0) }
        #expect(attachment != nil)

        #expect(
            harness.vmnet.service.ipv4Subnet(for: VmnetNetworkID(kind: .nat, scope: .vm(harness.owner))) != nil)
        #expect(harness.vmnet.operations.releasedNetworks.isEmpty)
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
