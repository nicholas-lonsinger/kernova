import Testing
import Foundation
import AppKit
import KernovaKit
import KernovaTestSupport
@testable import Kernova

@Suite("VMInstance Tests", .admissionGated)
@MainActor
struct VMInstanceTests {
    private func makeInstance(status: VMStatus = .stopped) -> VMInstance {
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .linux,
            bootMode: .efi
        )
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL, status: status)
    }

    // MARK: - Snapshot eligibility

    @Test("A live or stopped VM can be snapshotted; every other at-rest state cannot")
    func canTakeSnapshotCoversLiveAndStopped() {
        for status in [VMStatus.running, .paused] {
            let instance = makeInstance(status: status)
            instance.hasLiveVirtualMachineOverrideForTesting = true
            #expect(instance.canTakeSnapshot, "status \(status.displayName)")
        }
        #expect(makeInstance(status: .stopped).canTakeSnapshot)
        for status in [
            VMStatus.starting, .saving, .snapshotting, .restoring, .installing, .error, .initialBoot,
        ] {
            let instance = makeInstance(status: status)
            instance.hasLiveVirtualMachineOverrideForTesting = true
            #expect(instance.canTakeSnapshot == false, "status \(status.displayName)")
        }
    }

    @Test("A cold-paused VM's disks belong to a suspended session, so it cannot be captured")
    func coldPausedCannotTakeASnapshot() {
        let instance = makeInstance(status: .paused)
        instance.hasLiveVirtualMachineOverrideForTesting = false
        #expect(instance.canTakeSnapshot == false)
    }

    @Test("The capture kind follows what the VM has to capture")
    func snapshotKindFollowsLiveness() {
        for status in [VMStatus.running, .paused] {
            let instance = makeInstance(status: status)
            instance.hasLiveVirtualMachineOverrideForTesting = true
            #expect(instance.snapshotKindForCapture == .warm, "status \(status.displayName)")
        }
        #expect(makeInstance(status: .stopped).snapshotKindForCapture == .cold)
    }

    @Test("canRevertToSnapshot needs a snapshot to go back to")
    func revertNeedsASnapshot() {
        let instance = makeInstance(status: .stopped)
        #expect(instance.canRevertToSnapshot == false)

        instance.snapshotManifest = VMSnapshotManifest(snapshots: [VMSnapshot(name: "One")])
        #expect(instance.canRevertToSnapshot == true)
    }

    @Test("A running VM can be reverted — the revert discards the live session")
    func runningVMCanBeReverted() {
        let instance = makeInstance(status: .running)
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [VMSnapshot(name: "One")])
        #expect(instance.canRevertToSnapshot == true)
    }

    @Test("A VM mid-transition cannot be reverted")
    func transitioningVMCannotBeReverted() {
        for status in [VMStatus.starting, .saving, .snapshotting, .restoring, .installing] {
            let instance = makeInstance(status: status)
            instance.snapshotManifest = VMSnapshotManifest(snapshots: [VMSnapshot(name: "One")])
            #expect(instance.canRevertToSnapshot == false, "status \(status.displayName)")
        }
    }

    // MARK: - detailPaneMode

    @Test("detailPaneMode defaults to .display on a new instance")
    func detailPaneModeDefaultsToDisplay() {
        let instance = makeInstance()
        #expect(instance.detailPaneMode == .display)
    }

    @Test("detailPaneMode is per-instance (independent between VMs)")
    func detailPaneModeIsPerInstance() {
        let a = makeInstance()
        let b = makeInstance()
        a.detailPaneMode = .settings
        #expect(a.detailPaneMode == .settings)
        #expect(b.detailPaneMode == .display)
    }

    @Test("resetToStopped clears detailPaneMode back to .display")
    func resetToStoppedClearsDetailPaneMode() {
        let instance = makeInstance(status: .running)
        instance.detailPaneMode = .settings

        instance.resetToStopped()

        #expect(instance.detailPaneMode == .display)
        #expect(instance.status == .stopped)
    }

    // MARK: - tearDownSession

    @Test("tearDownSession clears pipes and the session without changing status")
    func tearDownSessionPreservesStatus() {
        let instance = makeInstance(status: .running)
        instance.serialInputPipe = Pipe()
        instance.serialOutputPipe = Pipe()

        instance.tearDownSession()

        #expect(instance.status == .running)
        #expect(instance.session == nil)
        #expect(instance.serialInputPipe == nil)
        #expect(instance.serialOutputPipe == nil)
    }

    @Test("tearDownSession resets a hidden (headless) displayMode to inline")
    func tearDownSessionResetsHiddenDisplayMode() {
        let instance = makeInstance(status: .running)
        instance.displayMode = .hidden

        instance.tearDownSession()

        #expect(instance.displayMode == .inline)
    }

    @Test("tearDownSession is idempotent")
    func tearDownSessionIdempotent() {
        let instance = makeInstance(status: .paused)
        instance.tearDownSession()
        instance.tearDownSession()

        #expect(instance.status == .paused)
        #expect(instance.session == nil)
        #expect(instance.serialInputPipe == nil)
        #expect(instance.serialOutputPipe == nil)
    }

    // MARK: - resetToStopped

    @Test("resetToStopped sets status to stopped and clears the session")
    func resetToStopped() {
        let instance = makeInstance(status: .running)
        // Simulate having a VM reference (we can't create a real VZVirtualMachine)
        #expect(instance.status == .running)

        instance.resetToStopped()

        #expect(instance.status == .stopped)
        #expect(instance.session == nil)
    }

    @Test("resetToStopped is idempotent when already stopped")
    func resetToStoppedIdempotent() {
        let instance = makeInstance(status: .stopped)
        instance.resetToStopped()
        #expect(instance.status == .stopped)
        #expect(instance.session == nil)
    }

    // MARK: - removeSaveFile

    @Test("removeSaveFile is a no-op when no save file exists")
    func removeSaveFileNoOp() {
        let instance = makeInstance()
        // Should not throw — silently succeeds
        instance.removeSaveFile()
        #expect(!instance.hasSaveFile)
    }

    @Test("removeSaveFile deletes an existing save file")
    func removeSaveFileDeletesFile() throws {
        let instance = makeInstance()

        // Create the bundle directory and a fake save file
        try FileManager.default.createDirectory(
            at: instance.bundleURL,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: instance.saveFileURL.path(percentEncoded: false),
            contents: Data("fake save".utf8)
        )

        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }

        #expect(FileManager.default.fileExists(atPath: instance.saveFileURL.path(percentEncoded: false)))

        instance.removeSaveFile()

        #expect(!FileManager.default.fileExists(atPath: instance.saveFileURL.path(percentEncoded: false)))
    }

    // MARK: - isColdPaused

    @Test("isColdPaused is true when paused with no live session")
    func isColdPausedTrue() {
        let instance = makeInstance(status: .paused)
        #expect(instance.session == nil)
        #expect(instance.isColdPaused == true)
    }

    @Test("isColdPaused is false when stopped")
    func isColdPausedFalseWhenStopped() {
        let instance = makeInstance(status: .stopped)
        #expect(instance.isColdPaused == false)
    }

    @Test("isColdPaused is false when running")
    func isColdPausedFalseWhenRunning() {
        let instance = makeInstance(status: .running)
        #expect(instance.isColdPaused == false)
    }

    // MARK: - hasLiveSession

    @Test(
        "hasLiveSession is true for a running or live-paused VM",
        arguments: [VMStatus.running, .paused])
    func hasLiveSessionWithLiveVM(status: VMStatus) {
        let instance = makeInstance(status: status)
        instance.hasLiveVirtualMachineOverrideForTesting = true
        #expect(instance.hasLiveSession == true)
    }

    @Test(
        "hasLiveSession is false without a live virtual machine",
        arguments: [VMStatus.running, .paused, .stopped, .error])
    func hasLiveSessionWithoutLiveVM(status: VMStatus) {
        let instance = makeInstance(status: status)
        #expect(instance.hasLiveSession == false)
    }

    @Test(
        "hasLiveSession is false mid-transition even with a live virtual machine",
        arguments: [VMStatus.saving, .restoring, .starting, .installing, .initialBoot])
    func hasLiveSessionIsFalseWhileTransitioning(status: VMStatus) {
        // A VM that has not settled at `.running`/`.paused` is not something the
        // termination pass can snapshot.
        let instance = makeInstance(status: status)
        instance.hasLiveVirtualMachineOverrideForTesting = true
        #expect(instance.hasLiveSession == false)
    }

    // MARK: - effectiveMachineIdentifierData

    @Test("effectiveMachineIdentifierData prefers the configuration field")
    func effectiveMachineIDPrefersConfiguration() {
        let instance = makeInstance()
        instance.configuration.machineIdentifierData = Data([1, 2, 3])
        #expect(instance.effectiveMachineIdentifierData == Data([1, 2, 3]))
    }

    @Test("effectiveMachineIdentifierData falls back to the bundle's identifier file")
    func effectiveMachineIDFallsBackToFile() throws {
        let instance = makeInstance()
        try FileManager.default.createDirectory(
            at: instance.bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }
        try Data([4, 5, 6]).write(to: instance.machineIdentifierURL)

        #expect(instance.configuration.machineIdentifierData == nil)
        #expect(instance.effectiveMachineIdentifierData == Data([4, 5, 6]))
    }

    @Test("effectiveMachineIdentifierData is nil with neither a configuration field nor a file")
    func effectiveMachineIDNilWhenAbsent() {
        let instance = makeInstance()
        #expect(instance.effectiveMachineIdentifierData == nil)
    }

    // MARK: - isKeepingAppAlive

    @Test("isKeepingAppAlive is true when preparing")
    func isKeepingAppAlivePreparing() {
        let instance = makeInstance(status: .stopped)
        let task = Task {}
        defer { task.cancel() }
        instance.preparingState = VMInstance.PreparingState(operation: .cloning, task: task)
        #expect(instance.isKeepingAppAlive == true)
    }

    @Test("isKeepingAppAlive is true for active statuses")
    func isKeepingAppAliveActive() {
        for status in [VMStatus.running, .starting, .saving, .restoring, .installing] {
            let instance = makeInstance(status: status)
            #expect(instance.isKeepingAppAlive == true)
        }
    }

    @Test("isKeepingAppAlive is false when cold-paused")
    func isKeepingAppAliveColdPaused() {
        let instance = makeInstance(status: .paused)
        #expect(instance.session == nil)
        #expect(instance.isKeepingAppAlive == false)
    }

    @Test("isKeepingAppAlive is false when stopped or error")
    func isKeepingAppAliveStoppedOrError() {
        for status in [VMStatus.stopped, .error] {
            let instance = makeInstance(status: status)
            #expect(instance.isKeepingAppAlive == false)
        }
    }

    // MARK: - canStop

    @Test("canStop is true when running (without live VM, tests model logic)")
    func canStopRunning() {
        let instance = makeInstance(status: .running)
        // status.canStop is true and isColdPaused is false
        #expect(instance.canStop == true)
    }

    @Test("canStop is false when stopped")
    func canStopStopped() {
        let instance = makeInstance(status: .stopped)
        #expect(instance.canStop == false)
    }

    @Test("canStop is false for cold-paused VM (paused without live VM)")
    func canStopColdPaused() {
        let instance = makeInstance(status: .paused)
        #expect(instance.isColdPaused == true)
        #expect(instance.canStop == false)
    }

    @Test("canStop is false during transitions")
    func canStopTransitions() {
        for status in [VMStatus.starting, .saving, .restoring, .installing] {
            let instance = makeInstance(status: status)
            #expect(instance.canStop == false)
        }
    }

    @Test("canStop is false in error state")
    func canStopError() {
        let instance = makeInstance(status: .error)
        #expect(instance.canStop == false)
    }

    // MARK: - canSave

    @Test("canSave is true when running (without live VM, tests model logic)")
    func canSaveRunning() {
        let instance = makeInstance(status: .running)
        // status.canSave is true and isColdPaused is false
        #expect(instance.canSave == true)
    }

    @Test("canSave is false when stopped")
    func canSaveStopped() {
        let instance = makeInstance(status: .stopped)
        #expect(instance.canSave == false)
    }

    @Test("canSave is false for cold-paused VM (paused without live VM)")
    func canSaveColdPaused() {
        let instance = makeInstance(status: .paused)
        #expect(instance.isColdPaused == true)
        #expect(instance.canSave == false)
    }

    @Test("canSave is false during transitions")
    func canSaveTransitions() {
        for status in [VMStatus.starting, .saving, .restoring, .installing] {
            let instance = makeInstance(status: status)
            #expect(instance.canSave == false)
        }
    }

    @Test("canSave is false in error state")
    func canSaveError() {
        let instance = makeInstance(status: .error)
        #expect(instance.canSave == false)
    }

    // MARK: - canForceStop

    @Test("canForceStop is true when running or transitioning (without live VM, tests model logic)")
    func canForceStopRunningAndTransitions() {
        for status in [VMStatus.running, .starting, .saving, .restoring] {
            let instance = makeInstance(status: status)
            #expect(instance.canForceStop == true)
        }
    }

    @Test("canForceStop is false for cold-paused VM (discard saved state is the only action)")
    func canForceStopColdPaused() {
        let instance = makeInstance(status: .paused)
        #expect(instance.isColdPaused == true)
        #expect(instance.canForceStop == false)
    }

    @Test("canForceStop is false when stopped or in error state")
    func canForceStopStoppedOrError() {
        for status in [VMStatus.stopped, .error, .initialBoot] {
            let instance = makeInstance(status: status)
            #expect(instance.canForceStop == false)
        }
    }

    // MARK: - canDelete

    @Test("canDelete is true when stopped, in error, or awaiting initial boot")
    func canDeleteInertStatuses() {
        for status in [VMStatus.stopped, .error, .initialBoot] {
            let instance = makeInstance(status: status)
            #expect(instance.canDelete == true)
        }
    }

    @Test("canDelete is true for a cold-paused VM (the saved state goes with the bundle)")
    func canDeleteColdPaused() {
        let instance = makeInstance(status: .paused)
        #expect(instance.isColdPaused == true)
        #expect(instance.canDelete == true)
    }

    @Test("canDelete is false for a live-paused VM (its VZVirtualMachine is still in memory)")
    func canDeleteLivePaused() {
        let instance = makeInstance(status: .paused)
        instance.hasLiveVirtualMachineOverrideForTesting = true
        #expect(instance.isLivePaused == true)
        #expect(instance.canDelete == false)
    }

    @Test("canDelete is false while running or transitioning")
    func canDeleteRunningAndTransitions() {
        for status in [VMStatus.running, .starting, .saving, .restoring, .installing] {
            let instance = makeInstance(status: status)
            #expect(instance.canDelete == false)
        }
    }

    @Test("canDelete is false while an import or clone is writing into the bundle")
    func canDeletePreparing() {
        // The toolbar's Move to Trash reads this predicate without a preparing
        // guard of its own, so the check has to live here to hold on every surface.
        let instance = makeInstance(status: .stopped)
        let task = Task {}
        defer { task.cancel() }
        instance.preparingState = VMInstance.PreparingState(operation: .cloning, task: task)
        #expect(instance.isPreparing == true)
        #expect(instance.canDelete == false)
    }

    // MARK: - Bundle Paths

    @Test("Bundle path URLs are correctly derived from bundleURL")
    func bundlePaths() {
        let instance = makeInstance()

        #expect(instance.diskImageURL.lastPathComponent == "Disk.asif")
        #expect(instance.auxiliaryStorageURL.lastPathComponent == "AuxiliaryStorage")
        #expect(instance.saveFileURL.lastPathComponent == "SaveFile.vzvmsave")
    }

    // MARK: - Serial Console

    @Test("resetToStopped clears serial pipes")
    func resetToStoppedClearsSerialPipes() {
        let instance = makeInstance(status: .running)
        instance.serialInputPipe = Pipe()
        instance.serialOutputPipe = Pipe()

        instance.resetToStopped()

        #expect(instance.serialInputPipe == nil)
        #expect(instance.serialOutputPipe == nil)
        #expect(instance.status == .stopped)
    }

    @Test("serialLogURL is forwarded from bundleLayout")
    func serialLogURL() {
        let instance = makeInstance()
        #expect(instance.serialLogURL.lastPathComponent == "serial.log")
    }

    // MARK: - Status Display Properties

    @Test("statusDisplayName returns Suspended when cold-paused")
    func statusDisplayNameColdPaused() {
        let instance = makeInstance(status: .paused)
        #expect(instance.isColdPaused == true)
        #expect(instance.statusDisplayName == "Suspended")
    }

    @Test("statusDisplayName delegates to status.displayName for non-paused states")
    func statusDisplayNameDelegates() {
        for status in [VMStatus.stopped, .running, .starting, .saving, .restoring, .installing, .error] {
            let instance = makeInstance(status: status)
            #expect(instance.statusDisplayName == status.displayName)
        }
    }

    @Test("statusDisplayNSColor returns systemOrange when cold-paused")
    func statusDisplayNSColorColdPaused() {
        let instance = makeInstance(status: .paused)
        #expect(instance.isColdPaused == true)
        #expect(instance.statusDisplayNSColor == .systemOrange)
    }

    @Test("statusDisplayNSColor maps non-paused states")
    func statusDisplayNSColorByStatus() {
        // Concrete gray (not `.secondaryLabelColor`) so the OS icon keeps its
        // stopped color on the selection highlight instead of inverting to white.
        #expect(makeInstance(status: .stopped).statusDisplayNSColor == .systemGray)
        #expect(makeInstance(status: .running).statusDisplayNSColor == .systemGreen)
        #expect(makeInstance(status: .starting).statusDisplayNSColor == .systemOrange)
        #expect(makeInstance(status: .error).statusDisplayNSColor == .systemRed)
    }

    @Test("statusToolTip mentions disk when cold-paused")
    func statusToolTipColdPaused() {
        let instance = makeInstance(status: .paused)
        #expect(instance.isColdPaused == true)
        let tip = instance.statusToolTip
        #expect(tip != nil)
        #expect(tip!.contains("disk"))
    }

    @Test("statusToolTip returns nil for non-paused states")
    func statusToolTipNilForNonPaused() {
        for status in [VMStatus.stopped, .running, .starting, .saving, .restoring, .installing, .error] {
            let instance = makeInstance(status: status)
            #expect(instance.statusToolTip == nil)
        }
    }

    @Test("statusToolTip carries the stored message in the error state")
    func statusToolTipError() {
        let instance = makeInstance(status: .error)
        instance.errorMessage = "The virtual machine failed to start."
        #expect(instance.statusToolTip == "The virtual machine failed to start.")
    }

    // MARK: - Network Attachment Recovery

    /// Wires a mock-backed coordinator onto `instance`, reading its live
    /// configuration the way the production wiring does.
    private func attachNetworkCoordinator(
        to instance: VMInstance,
        device: MockNetworkDeviceControl,
        provider: MockBridgedInterfaceProvider = MockBridgedInterfaceProvider()
    ) -> NetworkAttachmentCoordinator {
        let coordinator = NetworkAttachmentCoordinator(
            vmName: instance.name,
            device: device,
            interfaces: provider,
            linkObserver: MockNetworkLinkObserver(),
            // Pinned rather than read from the test host's signature, so the
            // plans these tests assert on don't vary with how it was signed.
            isVMNetworkingEntitled: false,
            retryDelays: [],
            isEligible: { [weak instance] in
                guard let instance else { return false }
                return instance.status == .running || instance.status == .paused
            },
            choice: { [weak instance] in instance?.configuration.networkChoice },
            onPendingChange: { [weak instance] in instance?.networkAttachmentPending = $0 })
        instance.networkAttachmentCoordinator = coordinator
        return coordinator
    }

    @Test("A running VM awaiting network reattach shows the warning tint and says why")
    func networkPendingShowsWarningTintAndToolTip() {
        let instance = makeInstance(status: .running)
        instance.networkAttachmentPending = true

        #expect(instance.statusDisplayNSColor == StatusColor.warning)
        // The wording names what is actually unavailable: the app-managed
        // network for Shared and Host Only, a host interface for Bridged.
        instance.configuration.networkMode = .shared
        #expect(
            instance.statusToolTip
                == "The Shared Network is unavailable. Kernova reconnects automatically.")
        instance.configuration.networkMode = .hostOnly
        #expect(
            instance.statusToolTip
                == "The Host Only network is unavailable. Kernova reconnects automatically.")
        instance.configuration.networkMode = .bridged
        #expect(instance.statusToolTip?.contains("network interface") == true)
    }

    @Test("applyLivePolicy forwards a network mode change to the coordinator")
    func applyLivePolicyForwardsNetworkChange() {
        let instance = makeInstance(status: .running)
        instance.configuration.networkEnabled = true
        instance.configuration.networkMode = .shared
        let device = MockNetworkDeviceControl(plan: .nat)
        let coordinator = attachNetworkCoordinator(
            to: instance, device: device,
            provider: MockBridgedInterfaceProvider(
                available: [BridgedInterface(identifier: "en0", localizedDisplayName: "Wi-Fi")]))
        coordinator.activate()
        #expect(device.appliedPlans.isEmpty)

        let old = instance.configuration
        instance.configuration.networkMode = .bridged
        instance.configuration.bridgedInterfaceIdentifier = "en0"
        instance.applyLivePolicy(oldConfig: old, newConfig: instance.configuration)

        #expect(device.appliedPlans == [.bridged("en0")])
    }

    @Test("applyLivePolicy ignores a network change while the VM is stopped")
    func applyLivePolicyIgnoresNetworkChangeWhileStopped() {
        let instance = makeInstance(status: .running)
        instance.configuration.networkEnabled = true
        instance.configuration.networkMode = .shared
        let device = MockNetworkDeviceControl()
        let coordinator = attachNetworkCoordinator(to: instance, device: device)
        coordinator.activate()
        #expect(device.appliedPlans == [.nat])
        instance.status = .stopped

        let old = instance.configuration
        instance.configuration.networkMode = .bridged
        instance.applyLivePolicy(oldConfig: old, newConfig: instance.configuration)

        #expect(device.appliedPlans == [.nat])
    }

    // MARK: - mayHoldAttachment

    /// The window between a session being created and its recovery coordinator
    /// being built: the configuration build has already attached the VM to the
    /// app-managed network, so answering from the absent coordinator would
    /// invite `rebuildNetworkIfIdle` to recreate the network under it.
    @Test("A live session holds its configured network before its coordinator exists")
    func mayHoldAttachmentBeforeTheCoordinatorIsBuilt() {
        let instance = makeInstance(status: .starting)
        instance.configuration.networkEnabled = true
        instance.configuration.networkMode = .shared
        instance.hasLiveVirtualMachineOverrideForTesting = true
        #expect(instance.networkAttachmentCoordinator == nil)

        #expect(instance.mayHoldAttachment(on: .shared))
        #expect(!instance.mayHoldAttachment(on: .hostOnly))
    }

    @Test("A live session with networking off holds nothing")
    func mayHoldAttachmentWithNetworkingOff() {
        let instance = makeInstance(status: .running)
        instance.configuration.networkEnabled = false
        instance.configuration.networkMode = .shared
        instance.hasLiveVirtualMachineOverrideForTesting = true

        #expect(!instance.mayHoldAttachment(on: .shared))
        #expect(!instance.mayHoldAttachment(on: .hostOnly))
    }

    /// Once the coordinator exists its mirror of the installed attachment is
    /// authoritative — a live mode switch leaves it disagreeing with the
    /// configuration in both directions until the swap lands, and an
    /// unentitled build realizes Shared as plain NAT, on no app-managed
    /// network at all.
    @Test(
        "The coordinator's applied attachment answers once it exists",
        arguments: [
            (NetworkAttachmentPlan.sharedVmnet, true),
            (NetworkAttachmentPlan.hostOnly, false),
            (NetworkAttachmentPlan.nat, false),
        ])
    func mayHoldAttachmentReadsTheAppliedPlan(plan: NetworkAttachmentPlan, holdsShared: Bool) {
        let instance = makeInstance(status: .running)
        instance.configuration.networkEnabled = true
        instance.configuration.networkMode = .shared
        instance.hasLiveVirtualMachineOverrideForTesting = true
        _ = attachNetworkCoordinator(to: instance, device: MockNetworkDeviceControl(plan: plan))

        #expect(instance.mayHoldAttachment(on: .shared) == holdsShared)
        #expect(instance.mayHoldAttachment(on: .hostOnly) == (plan == .hostOnly))
    }

    @Test("tearDownSession stops network recovery and clears the pending flag")
    func tearDownSessionStopsNetworkRecovery() {
        let instance = makeInstance(status: .running)
        instance.configuration.networkEnabled = true
        instance.configuration.networkMode = .bridged
        let device = MockNetworkDeviceControl()
        let coordinator = attachNetworkCoordinator(to: instance, device: device)
        coordinator.activate()
        #expect(instance.networkAttachmentPending)

        instance.tearDownSession()

        #expect(instance.networkAttachmentCoordinator == nil)
        #expect(!instance.networkAttachmentPending)
    }

    // MARK: - Lifecycle Action Labels

    @Test("startAction is .start without a pending install context")
    func startActionDefault() {
        let instance = makeInstance(status: .stopped)
        #expect(instance.startAction == .start)
        #expect(instance.startAction.label == "Start")
    }

    @Test("startAction is .install with a pending install context and no resumable download")
    func startActionInstall() {
        let instance = makeInstance(status: .stopped)
        instance.configuration.installContext = MacOSInstallContext(source: .downloadLatest)
        #expect(instance.hasResumableInstallDownload == false)
        #expect(instance.startAction == .install)
        #expect(instance.startAction.label == "Install")
    }

    /// Builds a stopped VM with an install context whose download destination has
    /// a sibling `.kernovadownload` bundle seeded on disk.
    ///
    /// `partialBytes` is what the bundle's `data` file holds: pass `nil` for the
    /// husk a finalize leaves when its disposal fails (directory and metadata
    /// present, `data` already moved to the destination). Returns the temp
    /// directory so the caller can clean it up.
    private func makeInstanceWithSeededDownloadBundle(
        partialBytes: Data?,
        source: MacOSInstallContext.Source = .downloadLatest
    ) throws -> (instance: VMInstance, temp: URL) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMInstanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let destination = temp.appendingPathComponent("RestoreImage.ipsw")
        let bundle = DownloadBundle(url: DownloadService.resumeBundleURL(for: destination))
        try bundle.prepareForFreshDownload(
            with: DownloadBundleMetadata(
                originalURL: URL(fileURLWithPath: "/tmp/RestoreImage.ipsw"),
                etag: nil,
                lastModified: nil,
                createdAt: Date()
            )
        )
        if let partialBytes {
            try partialBytes.write(to: bundle.dataURL)
        } else {
            try FileManager.default.removeItem(at: bundle.dataURL)
        }
        // Guards against a vacuous pass: the husk case asserts a *false*
        // `hasResumableInstallDownload`, which an absent bundle would also
        // produce. The directory must be there for the test to mean anything.
        #expect(bundle.exists)

        let instance = makeInstance(status: .stopped)
        instance.configuration.installContext = MacOSInstallContext(
            source: source,
            downloadDestinationPath: destination.path(percentEncoded: false)
        )
        return (instance, temp)
    }

    @Test("startAction is .install when the bundle is a data-less husk")
    func startActionInstallWithHuskBundle() throws {
        // A finalize whose disposal failed leaves the bundle directory (and its
        // metadata) behind with `data` already moved to the destination. It has
        // no bytes to resume from, so it must not offer "Resume Install".
        let (instance, temp) = try makeInstanceWithSeededDownloadBundle(partialBytes: nil)
        defer { try? FileManager.default.removeItem(at: temp) }

        #expect(instance.hasResumableInstallDownload == false)
        #expect(instance.startAction == .install)
        #expect(instance.startAction.label == "Install")
    }

    @Test(
        "startAction is .resumeInstall when the bundle still holds partial bytes",
        arguments: [
            MacOSInstallContext.Source.downloadLatest, .catalogVersion, .customURL,
        ]
    )
    func startActionResumeInstallWithPartialBytes(source: MacOSInstallContext.Source) throws {
        // Every downloading source writes the same sidecar and resumes through
        // the same path, so all three offer "Resume Install".
        let (instance, temp) = try makeInstanceWithSeededDownloadBundle(
            partialBytes: Data(repeating: 0x11, count: 1024),
            source: source
        )
        defer { try? FileManager.default.removeItem(at: temp) }

        #expect(instance.hasResumableInstallDownload == true)
        #expect(instance.startAction == .resumeInstall)
        #expect(instance.startAction.label == "Resume Install")
    }

    @Test("startAction is .install for a local-file install beside a partial bundle")
    func startActionInstallForLocalFileSource() throws {
        // A local-file install never downloads, so a bundle left at the same
        // path by an earlier attempt says nothing about what Start will do.
        let (instance, temp) = try makeInstanceWithSeededDownloadBundle(
            partialBytes: Data(repeating: 0x11, count: 1024),
            source: .localFile
        )
        defer { try? FileManager.default.removeItem(at: temp) }

        #expect(instance.hasResumableInstallDownload == false)
        #expect(instance.startAction == .install)
    }

    @Test("startAction is .download with a pending Linux image and nothing partial on disk")
    func startActionDownload() {
        let instance = makeInstance(status: .stopped)
        instance.configuration.linuxInstallContext = LinuxInstallContext(
            source: .catalogEntry(makeLinuxCatalogEntry()))

        // No destination until the mirror is asked, which is exactly when there
        // is nothing to resume from.
        #expect(instance.hasResumableInstallDownload == false)
        #expect(instance.startAction == .download)
        #expect(instance.startAction.label == "Download")
    }

    @Test("startAction is .resumeDownload when a Linux image's bundle holds partial bytes")
    func startActionResumeDownload() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMInstanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let destination = temp.appendingPathComponent("debian-13.6.0-arm64-netinst.iso")
        let bundle = DownloadBundle(url: DownloadService.resumeBundleURL(for: destination))
        try bundle.prepareForFreshDownload(
            with: DownloadBundleMetadata(
                originalURL: URL(fileURLWithPath: destination.path(percentEncoded: false)),
                etag: nil, lastModified: nil, createdAt: Date()))
        try Data(repeating: 0x11, count: 1024).write(to: bundle.dataURL)

        let instance = makeInstance(status: .stopped)
        instance.configuration.linuxInstallContext = LinuxInstallContext(
            source: .catalogEntry(makeLinuxCatalogEntry()),
            downloadDestinationPath: destination.path(percentEncoded: false))

        #expect(instance.hasResumableInstallDownload == true)
        #expect(instance.startAction == .resumeDownload)
        #expect(instance.startAction.label == "Resume Download")
    }

    @Test("stopActionMenuTitle names the discard consequence when cold-paused")
    func stopActionMenuTitleColdPaused() {
        let instance = makeInstance(status: .paused)
        #expect(instance.isColdPaused == true)
        #expect(instance.stopActionMenuTitle == "Discard Saved State…")
        #expect(instance.stopActionToolbarLabel == "Discard Saved State")
    }

    @Test("stopActionMenuTitle is Stop for non-cold-paused states")
    func stopActionMenuTitleDefault() {
        for status in [VMStatus.stopped, .running, .starting] {
            let instance = makeInstance(status: status)
            #expect(instance.stopActionMenuTitle == "Stop")
            #expect(instance.stopActionToolbarLabel == "Stop")
        }
    }

    // MARK: - Preparing State

    @Test("preparingState defaults to nil and isPreparing to false")
    func preparingStateDefaultsNil() {
        let instance = makeInstance()
        #expect(instance.preparingState == nil)
        #expect(instance.isPreparing == false)
    }

    @Test("isPreparing is true when preparingState is set")
    func isPreparingTrueWhenSet() {
        let instance = makeInstance()
        let task = Task {}
        instance.preparingState = VMInstance.PreparingState(operation: .cloning, task: task)
        #expect(instance.isPreparing == true)

        instance.preparingState = nil
        #expect(instance.isPreparing == false)
        task.cancel()
    }

    @Test("statusDisplayName returns preparing label when isPreparing")
    func statusDisplayNamePreparing() {
        let instance = makeInstance()
        let task = Task {}
        defer { task.cancel() }

        instance.preparingState = VMInstance.PreparingState(operation: .cloning, task: task)
        #expect(instance.statusDisplayName == "Cloning\u{2026}")

        instance.preparingState = VMInstance.PreparingState(operation: .importing, task: task)
        #expect(instance.statusDisplayName == "Importing\u{2026}")
    }

    @Test("statusDisplayNSColor returns systemOrange when isPreparing")
    func statusDisplayNSColorPreparing() {
        let instance = makeInstance()
        let task = Task {}
        defer { task.cancel() }
        instance.preparingState = VMInstance.PreparingState(operation: .cloning, task: task)
        #expect(instance.statusDisplayNSColor == .systemOrange)
    }

    @Test("statusToolTip returns preparing label when isPreparing")
    func statusToolTipPreparing() {
        let instance = makeInstance()
        let task = Task {}
        defer { task.cancel() }
        instance.preparingState = VMInstance.PreparingState(operation: .cloning, task: task)
        #expect(instance.statusToolTip == "Cloning\u{2026}")
    }

    @Test("PreparingOperation cancelLabel and cancelAlertTitle")
    func preparingOperationLabels() {
        #expect(VMInstance.PreparingOperation.cloning.cancelLabel == "Cancel Clone")
        #expect(VMInstance.PreparingOperation.cloning.cancelAlertTitle == "Cancel Clone?")
        #expect(VMInstance.PreparingOperation.importing.cancelLabel == "Cancel Import")
        #expect(VMInstance.PreparingOperation.importing.cancelAlertTitle == "Cancel Import?")
    }

    @Test("PreparingOperation displayNoun")
    func preparingOperationDisplayNoun() {
        #expect(VMInstance.PreparingOperation.cloning.displayNoun == "Clone")
        #expect(VMInstance.PreparingOperation.importing.displayNoun == "Import")
    }

    // MARK: - agentStatus dispatch
    //
    // `VMInstance.agentStatus` is the single read site for the UI; it must
    // dispatch by `configuration.guestOS`:
    //   - macOS guests source it from `vsockControlService` (the always-on
    //     control channel, independent of clipboard sharing).
    //   - Linux guests source it from `clipboardService` cast to
    //     `SpiceClipboardService` (`spice-vdagent` is user-installed; only
    //     `.waiting` / `.current` are reachable).
    //
    // These tests lock in the switch so a future refactor can't accidentally
    // fall through to the wrong service per OS.

    private func makeInstance(guestOS: VMGuestOS) -> VMInstance {
        let bootMode: VMBootMode = guestOS == .macOS ? .macOS : .efi
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: guestOS,
            bootMode: bootMode
        )
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL, status: .stopped)
    }

    @Test("agentStatus is .waiting on a macOS instance with no control service set")
    func agentStatusMacOSDefaultsToWaiting() {
        let instance = makeInstance(guestOS: .macOS)
        #expect(instance.vsockControlService == nil)
        #expect(instance.agentStatus == .waiting)
    }

    @Test("agentStatus is .waiting on a Linux instance with no clipboard service set")
    func agentStatusLinuxDefaultsToWaiting() {
        let instance = makeInstance(guestOS: .linux)
        #expect(instance.clipboardService == nil)
        #expect(instance.agentStatus == .waiting)
    }

    @Test("agentStatus on macOS does NOT fall through to clipboardService — control is the only source")
    func agentStatusMacOSIgnoresClipboardService() {
        // Set a SpiceClipboardService on a macOS instance — an obvious
        // misconfiguration the dispatch shouldn't dignify. macOS should still
        // report `.waiting` because vsockControlService is nil; if dispatch
        // accidentally fell through to clipboardService, this would surface
        // the SPICE service's own `.waiting` (same value, but for the wrong
        // reason — and `.current` if the SPICE service were connected).
        let instance = makeInstance(guestOS: .macOS)
        instance.clipboardService = SpiceClipboardService(
            inputPipe: Pipe(),
            outputPipe: Pipe()
        )
        #expect(instance.vsockControlService == nil)
        #expect(instance.agentStatus == .waiting)
    }

    @Test("agentStatus on Linux dispatches to clipboardService cast as SpiceClipboardService")
    func agentStatusLinuxDispatchesToSpice() {
        let instance = makeInstance(guestOS: .linux)
        let spice = SpiceClipboardService(inputPipe: Pipe(), outputPipe: Pipe())
        instance.clipboardService = spice
        // Newly-constructed SPICE service is `.waiting` (no handshake yet) —
        // dispatch returns that same value, proving the cast + access path runs.
        #expect(spice.agentStatus == .waiting)
        #expect(instance.agentStatus == .waiting)
    }

    // MARK: - Session Events

    @Test("a session event whose id matches no live session is dropped")
    func staleSessionEventIsDropped() {
        let instance = makeInstance(status: .running)
        // No session attached: any delivered id is stale — the event a
        // torn-down session's guest stop produces after a fresh start.
        instance.deliverSessionEvent(.guestDidStop, from: UUID())
        #expect(instance.status == .running)
    }

    @Test("guestDidStop resets the instance to stopped")
    func guestDidStopEventResets() {
        let instance = makeInstance(status: .running)
        instance.serialInputPipe = Pipe()
        instance.handleSessionEvent(.guestDidStop)
        #expect(instance.status == .stopped)
        #expect(instance.serialInputPipe == nil)
    }

    @Test("didStopWithError tears the session down and records the error")
    func didStopWithErrorEventRecordsError() {
        let instance = makeInstance(status: .running)
        instance.serialInputPipe = Pipe()
        let failure = NSError(
            domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        instance.handleSessionEvent(.didStopWithError(failure))
        #expect(instance.status == .error)
        #expect(instance.errorMessage == "boom")
        #expect(instance.serialInputPipe == nil)
    }

    @Test("networkAttachmentDisconnected forwards to the recovery coordinator")
    func networkDisconnectedEventForwardsToCoordinator() {
        let instance = makeInstance(status: .running)
        let device = MockNetworkDeviceControl(plan: .nat)
        let coordinator = NetworkAttachmentCoordinator(
            vmName: "Test VM",
            device: device,
            interfaces: MockBridgedInterfaceProvider(available: [], primary: nil),
            linkObserver: MockNetworkLinkObserver(),
            vmnetNetworks: MockVmnetNetworkProvider(),
            isVMNetworkingEntitled: false,
            retryDelays: [],
            choice: { NetworkChoice(mode: .shared, bridgedInterfaceIdentifier: nil) },
            onPendingChange: { _ in })
        instance.networkAttachmentCoordinator = coordinator
        coordinator.activate()
        #expect(device.appliedPlans.isEmpty)

        instance.handleSessionEvent(
            .networkAttachmentDisconnected(NSError(domain: "test", code: 2)))

        // The framework-nil'd mirror is cleared and the chosen mode reattached.
        #expect(device.appliedPlans == [.nat])
        #expect(device.currentPlan == .nat)
    }

    // MARK: - Agent Post-Start Watchdog
    //
    // The watchdog flips `agentExpectedButMissing` after a grace period when:
    //   - The guest is macOS,
    //   - The VM is `.running` (a frozen guest can't answer),
    //   - `lastSeenAgentVersion` is set (so we have a baseline expectation),
    //   - No agent is connected on the control channel already,
    //   - No `setupState` is in progress, and
    //   - No Hello arrives during the grace window.
    // Tests inject a millisecond-scale grace so the suite stays fast.

    /// Builds a macOS VMInstance with a known `lastSeenAgentVersion`.
    ///
    /// The caller is responsible for explicitly clearing the watchdog if needed
    /// across tests.
    private func makeMacOSInstanceWithAgentInstalled(
        lastSeen: String = "0.9.2",
        lastSeenGuestOSVersion: String? = nil,
        setupState: GuestSetupState? = nil
    ) -> VMInstance {
        var config = VMConfiguration(
            name: "macOS Watchdog Test",
            guestOS: .macOS,
            bootMode: .macOS
        )
        config.lastSeenAgentVersion = lastSeen
        config.lastSeenGuestOSVersion = lastSeenGuestOSVersion
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL, status: .running)
        instance.setupState = setupState
        return instance
    }

    /// Guest-side `Hello` for tests that drive a real `VsockControlService`.
    private func makeGuestHelloFrame(agentVersion: String) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities = KernovaCapability.controlChannelDefaults
            $0.agentInfo = Kernova_V1_AgentInfo.with {
                $0.os = "macOS"
                $0.osVersion = "26.0"
                $0.agentVersion = agentVersion
            }
        }
        return frame
    }

    // Sized past macos-26 GitHub Actions MainActor jitter, which far exceeds
    // local hardware (docs/TESTING.md "Async waits in tests").
    private static let testWatchdogGrace: Duration = .milliseconds(200)

    @Test("Watchdog flips agentExpectedButMissing when no Hello arrives in the grace window")
    func watchdogFiresWhenSilent() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)

        // Await the watchdog task itself rather than polling the flag: the task
        // completes exactly when the grace elapses and flips the flag, so there
        // is no wall-clock deadline to lose under CI MainActor contention.
        await instance.agentPostStartTaskForTesting?.value
        #expect(instance.agentExpectedButMissing == true)
        #expect(instance.agentStatus == .expectedMissing(expected: "0.9.2"))
    }

    @Test("Cancelling the watchdog before grace prevents firing")
    func watchdogCancelledStaysQuiet() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        instance.startAgentPostStartWatchdog(grace: .seconds(5))

        // Cancel well before the grace elapses — the timer task must not
        // flip the flag after cancellation. Use a comfortably long
        // settle window (5× the grace would be 1 s, but 5× of *what we
        // expect* doesn't help here; we just need to outlast scheduler
        // jitter on a cancelled task that should never fire).
        instance.cancelAgentPostStartWatchdog()
        try await Task.sleep(for: .milliseconds(500))
        #expect(instance.agentExpectedButMissing == false)
    }

    @Test("Watchdog is a no-op when lastSeenAgentVersion is nil")
    func watchdogNoopWithoutPersistedVersion() async throws {
        // Fresh macOS VM, no prior agent — the .waiting nudge stays the
        // appropriate signal, the louder "didn't reconnect" badge would be
        // misleading.
        let config = VMConfiguration(
            name: "Fresh macOS",
            guestOS: .macOS,
            bootMode: .macOS
        )
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL, status: .running)

        // Wait noticeably past the grace so a broken guard would have a
        // real chance to mis-fire. 3× grace is plenty.
        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)
        try await Task.sleep(for: Self.testWatchdogGrace * 3)
        #expect(instance.agentExpectedButMissing == false)
    }

    @Test("Watchdog is a no-op for Linux guests")
    func watchdogNoopForLinux() async throws {
        // Linux uses spice-vdagent, which the host doesn't fingerprint —
        // the watchdog has no business firing here.
        var config = VMConfiguration(
            name: "Linux VM",
            guestOS: .linux,
            bootMode: .efi
        )
        config.lastSeenAgentVersion = "should-be-ignored"
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL, status: .running)

        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)
        try await Task.sleep(for: Self.testWatchdogGrace * 3)
        #expect(instance.agentExpectedButMissing == false)
    }

    @Test("Watchdog is a no-op for the whole of a recovery-booted session")
    func watchdogNoopAfterRecoveryBoot() async throws {
        // Recovery never runs the agent, so its silence proves nothing — the
        // "didn't reconnect" badge would be false and clearing the stored guest
        // OS version would erase a value that is not in doubt. Session state,
        // not a per-call flag: a pause/resume inside a Recovery session reaches
        // the same arm site with no idea a Recovery boot happened.
        let instance = makeMacOSInstanceWithAgentInstalled(
            lastSeenGuestOSVersion: "Version 26.0 (Build 25A123)")
        instance.bootedIntoRecovery = true

        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)
        try await Task.sleep(for: Self.testWatchdogGrace * 3)
        #expect(instance.agentExpectedButMissing == false)
        #expect(instance.configuration.lastSeenGuestOSVersion == "Version 26.0 (Build 25A123)")
        #expect(instance.configuration.agentInstallNudgeDismissed == false)
    }

    @Test("tearDownSession clears the recovery-boot flag")
    func tearDownSessionClearsRecoveryFlag() {
        // Per-session, like the rest of the watchdog state: the next boot is
        // free to be an ordinary one.
        let instance = makeMacOSInstanceWithAgentInstalled()
        instance.bootedIntoRecovery = true

        instance.tearDownSession()
        #expect(!instance.bootedIntoRecovery)
    }

    @Test("Watchdog is a no-op while macOS install is in progress")
    func watchdogNoopDuringMacOSInstall() async throws {
        // No agent exists during install; no point arming the watchdog.
        let setupState = GuestSetupState.macOSInstall(hasDownloadStep: true)
        let instance = makeMacOSInstanceWithAgentInstalled(setupState: setupState)

        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)
        try await Task.sleep(for: Self.testWatchdogGrace * 3)
        #expect(instance.agentExpectedButMissing == false)
    }

    @Test(
        "Watchdog is a no-op unless the VM is running",
        arguments: [
            VMStatus.paused, .saving, .restoring, .stopped,
        ])
    func watchdogNoopUnlessRunning(status: VMStatus) async throws {
        // A live-paused guest is frozen: it cannot say Hello, so a grace clock
        // running against it would blame the agent for the user's pause. The
        // control channel settles for silence at the same time, which is what
        // re-arms the watchdog — hence the guard rather than caller discipline.
        let instance = makeMacOSInstanceWithAgentInstalled()
        instance.status = status

        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)
        #expect(instance.agentPostStartTaskForTesting == nil)
        try await Task.sleep(for: Self.testWatchdogGrace * 3)
        #expect(instance.agentExpectedButMissing == false)
    }

    @Test("Watchdog is a no-op while the agent is connected")
    func watchdogNoopWhileAgentConnected() async throws {
        // Re-arm sites (resume, and the control channel dying) fire without
        // checking whether an agent is already talking; nothing to wait for
        // means nothing to arm.
        let instance = makeMacOSInstanceWithAgentInstalled()
        let (guestFd, hostFd) = try makeRawSocketPair()
        let guest = VsockChannel(fileDescriptor: guestFd)
        let host = VsockChannel(fileDescriptor: hostFd)
        guest.start()
        host.start()
        defer { guest.close() }

        let control = VsockControlService(channel: host, label: "watchdog-test")
        instance.vsockControlService = control
        control.start()
        defer { control.stop() }

        try guest.send(makeGuestHelloFrame(agentVersion: "0.9.2"))
        try await waitForChange { control.agentVersion != nil }

        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)
        #expect(instance.agentPostStartTaskForTesting == nil)
    }

    @Test("startAgentPostStartWatchdog is idempotent when already armed")
    func watchdogIdempotent() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        // Original timer with a long grace so we can be sure the second
        // call's would-be tiny grace has elapsed long before the original
        // would naturally fire. If the second call had taken effect, the
        // flag would be true after we sleep below.
        instance.startAgentPostStartWatchdog(grace: .seconds(30))
        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)

        try await Task.sleep(for: Self.testWatchdogGrace * 3)
        #expect(instance.agentExpectedButMissing == false)
    }

    @Test("Watchdog firing also clears a previously-dismissed install nudge and persists the change")
    func watchdogClearsAgentInstallNudgeDismissed() async throws {
        // Scenario: user previously installed the agent (lastSeenAgentVersion
        // set) and earlier dismissed the install nudge for this VM. The
        // agent now fails to reconnect after boot; the watchdog fires
        // .expectedMissing AND resets the dismissed flag so any future
        // .waiting (e.g. they wipe + reinstall the VM) is not silently
        // suppressed by their old preference.
        let instance = makeMacOSInstanceWithAgentInstalled()
        instance.configuration.agentInstallNudgeDismissed = true

        var persistCallCount = 0
        instance.onUpdateConfiguration = { mutate in
            mutate(&instance.configuration)
            persistCallCount += 1
        }

        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)

        await instance.agentPostStartTaskForTesting?.value
        #expect(instance.agentExpectedButMissing == true)
        #expect(instance.configuration.agentInstallNudgeDismissed == false)
        #expect(persistCallCount == 1)
    }

    @Test("Watchdog firing clears the stored guest OS version in the same persist")
    func watchdogClearsGuestOSVersion() async throws {
        // The agent that vouched for the OS version never reconnected, so the
        // value is unverifiable — Unknown must overwrite it rather than let a
        // stale version linger (the guest may have been wiped or upgraded).
        let instance = makeMacOSInstanceWithAgentInstalled(
            lastSeenGuestOSVersion: "Version 26.0 (Build 25A123)")

        var persistCallCount = 0
        instance.onUpdateConfiguration = { mutate in
            mutate(&instance.configuration)
            persistCallCount += 1
        }

        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)

        await instance.agentPostStartTaskForTesting?.value
        #expect(instance.agentExpectedButMissing == true)
        #expect(instance.configuration.lastSeenGuestOSVersion == nil)
        #expect(persistCallCount == 1)
    }

    @Test("Watchdog firing leaves an undismissed nudge alone (no spurious persist)")
    func watchdogDoesNotPersistWhenDismissalAlreadyClear() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        // Default: agentInstallNudgeDismissed == false
        var persistCallCount = 0
        instance.onUpdateConfiguration = { mutate in
            mutate(&instance.configuration)
            persistCallCount += 1
        }

        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)

        await instance.agentPostStartTaskForTesting?.value
        #expect(instance.agentExpectedButMissing == true)
        #expect(persistCallCount == 0)
    }

    @Test("A mid-session firing leaves the nudge dismissal and guest OS version alone")
    func watchdogPreservesPersistedStateAfterAMidSessionDeath() async throws {
        // The clearing exists for an agent that never showed up: nothing
        // vouched for the stored OS version, and the install nudge should come
        // back. After a Hello this session both facts are backed by evidence
        // the session produced, and `agentInstallNudgeDismissed` is a user
        // preference nothing restores — a dropped channel is not enough to
        // reverse it.
        let instance = makeMacOSInstanceWithAgentInstalled()
        instance.configuration.agentInstallNudgeDismissed = true

        var persistCallCount = 0
        instance.onUpdateConfiguration = { mutate in
            mutate(&instance.configuration)
            persistCallCount += 1
        }

        instance.recordObservedAgentInfo(
            ObservedAgentInfo(agentVersion: "0.9.2", osVersion: "Version 26.0 (Build 25A123)"))
        #expect(instance.hasSeenAgentThisSession)
        let persistsAfterHello = persistCallCount

        // The agent goes away mid-session and never comes back.
        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)
        await instance.agentPostStartTaskForTesting?.value

        // The badge still escalates — that is the whole point of #706.
        #expect(instance.agentExpectedButMissing == true)
        #expect(instance.agentStatus == .expectedMissing(expected: "0.9.2"))
        #expect(instance.configuration.agentInstallNudgeDismissed == true)
        #expect(instance.configuration.lastSeenGuestOSVersion == "Version 26.0 (Build 25A123)")
        #expect(persistCallCount == persistsAfterHello)
    }

    @Test("tearDownSession clears hasSeenAgentThisSession")
    func tearDownSessionClearsSeenAgentFlag() {
        // The flag is per-session: the next boot's no-show must be free to
        // rewrite persisted agent state again.
        let instance = makeMacOSInstanceWithAgentInstalled()
        instance.recordObservedAgentInfo(ObservedAgentInfo(agentVersion: "0.9.2", osVersion: "26.0"))
        #expect(instance.hasSeenAgentThisSession)

        instance.tearDownSession()
        #expect(!instance.hasSeenAgentThisSession)
    }

    @Test("tearDownSession clears agentExpectedButMissing and cancels the watchdog")
    func tearDownSessionResetsWatchdogState() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        // Drive the flag manually to simulate the watchdog having fired.
        instance.agentExpectedButMissing = true
        instance.startAgentPostStartWatchdog(grace: .seconds(60))

        instance.tearDownSession()

        #expect(instance.agentExpectedButMissing == false)
        // Re-arming after teardown should now succeed — the prior task was
        // cancelled, so the idempotency guard does not block this.
        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)
        await instance.agentPostStartTaskForTesting?.value
        #expect(instance.agentExpectedButMissing == true)
    }

    @Test("agentStatus surfaces .expectedMissing only when both the flag and persisted version are set")
    func agentStatusExpectedMissingRequiresBoth() {
        let instance = makeMacOSInstanceWithAgentInstalled()
        // Flag alone but version present → .expectedMissing
        instance.agentExpectedButMissing = true
        #expect(instance.agentStatus == .expectedMissing(expected: "0.9.2"))

        // Wipe the persisted version: the synthesizer guard falls back to
        // .waiting rather than producing .expectedMissing(expected: "").
        instance.configuration.lastSeenAgentVersion = nil
        #expect(instance.agentStatus == .waiting)
    }

    // MARK: - recordObservedAgentInfo

    @Test("recordObservedAgentInfo persists when the version changes")
    func recordObservedPersistsOnChange() {
        let instance = makeMacOSInstanceWithAgentInstalled(lastSeen: "0.9.0")
        var savedConfig: VMConfiguration?
        instance.onUpdateConfiguration = { mutate in
            mutate(&instance.configuration)
            savedConfig = instance.configuration
        }

        instance.recordObservedAgentInfo(ObservedAgentInfo(agentVersion: "0.9.2", osVersion: nil))

        #expect(instance.configuration.lastSeenAgentVersion == "0.9.2")
        #expect(savedConfig?.lastSeenAgentVersion == "0.9.2")
    }

    @Test("recordObservedAgentInfo populates both last-seen fields for fresh VMs")
    func recordObservedSetsFromNil() {
        // Simulates the very first time an agent connects to a fresh VM —
        // the persisted fields start nil and the observer must seed them,
        // in a single write.
        let config = VMConfiguration(name: "Fresh", guestOS: .macOS, bootMode: .macOS)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL, status: .running)
        var saveCount = 0
        instance.onUpdateConfiguration = { mutate in
            mutate(&instance.configuration)
            saveCount += 1
        }

        instance.recordObservedAgentInfo(
            ObservedAgentInfo(agentVersion: "0.9.0", osVersion: "Version 26.0 (Build 25A123)"))

        #expect(instance.configuration.lastSeenAgentVersion == "0.9.0")
        #expect(instance.configuration.lastSeenGuestOSVersion == "Version 26.0 (Build 25A123)")
        #expect(saveCount == 1)
    }

    @Test("recordObservedAgentInfo does not persist when both fields are unchanged")
    func recordObservedSkipsRedundantWrites() {
        let instance = makeMacOSInstanceWithAgentInstalled(
            lastSeen: "0.9.2", lastSeenGuestOSVersion: "Version 26.0 (Build 25A123)")
        var saveCount = 0
        instance.onUpdateConfiguration = { mutate in
            mutate(&instance.configuration)
            saveCount += 1
        }

        let info = ObservedAgentInfo(
            agentVersion: "0.9.2", osVersion: "Version 26.0 (Build 25A123)")
        instance.recordObservedAgentInfo(info)
        instance.recordObservedAgentInfo(info)

        // Two identical Hellos must not produce a single disk write.
        // Storage churn would re-fire VMDirectoryWatcher reconcile on every
        // heartbeat-driven reconnect.
        #expect(saveCount == 0)
    }

    @Test("recordObservedAgentInfo persists an OS-version change on a same-agent-version reconnect")
    func recordObservedPersistsOSVersionChangeAlone() {
        // The guest took a macOS update; the agent survived it at the same
        // version. The new OS version must still land on disk.
        let instance = makeMacOSInstanceWithAgentInstalled(
            lastSeen: "0.9.2", lastSeenGuestOSVersion: "Version 26.0 (Build 25A123)")
        var saveCount = 0
        instance.onUpdateConfiguration = { mutate in
            mutate(&instance.configuration)
            saveCount += 1
        }

        instance.recordObservedAgentInfo(
            ObservedAgentInfo(agentVersion: "0.9.2", osVersion: "Version 26.1 (Build 25B456)"))

        #expect(instance.configuration.lastSeenGuestOSVersion == "Version 26.1 (Build 25B456)")
        #expect(saveCount == 1)
    }

    @Test("recordObservedAgentInfo overwrites a stored OS version with nil when the agent reports none")
    func recordObservedNilOSVersionOverwrites() {
        // An agent that stops vouching for an OS version must clear the stored
        // one — Unknown beats stale.
        let instance = makeMacOSInstanceWithAgentInstalled(
            lastSeen: "0.9.2", lastSeenGuestOSVersion: "Version 26.0 (Build 25A123)")
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }

        instance.recordObservedAgentInfo(ObservedAgentInfo(agentVersion: "0.9.2", osVersion: nil))

        #expect(instance.configuration.lastSeenGuestOSVersion == nil)
    }

    @Test("recordObservedAgentInfo fires onAgentBecameCurrent for a current version")
    func recordObservedFiresBecameCurrentOnCurrentVersion() throws {
        let bundled = try #require(KernovaMacOSAgentInfo.bundledVersion)
        // lastSeen must differ from the reported version so the persist guard
        // doesn't short-circuit before the auto-eject hook.
        let instance = makeMacOSInstanceWithAgentInstalled(lastSeen: "0.0.0")
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }
        var fired = 0
        instance.onAgentBecameCurrent = { fired += 1 }

        instance.recordObservedAgentInfo(ObservedAgentInfo(agentVersion: bundled, osVersion: nil))

        #expect(fired == 1)
    }

    @Test("recordObservedAgentInfo does not fire onAgentBecameCurrent for an outdated version")
    func recordObservedSkipsBecameCurrentOnOutdated() throws {
        let bundled = try #require(KernovaMacOSAgentInfo.bundledVersion)
        // Only meaningful when the bundled version is strictly newer than the
        // sentinel, so "0.0.1" genuinely classifies as outdated.
        try #require(bundled.compare("0.0.1", options: .numeric) == .orderedDescending)
        let instance = makeMacOSInstanceWithAgentInstalled(lastSeen: "0.0.0")
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }
        var fired = 0
        instance.onAgentBecameCurrent = { fired += 1 }

        instance.recordObservedAgentInfo(ObservedAgentInfo(agentVersion: "0.0.1", osVersion: nil))

        #expect(fired == 0)
    }

    @Test("recordObservedAgentInfo does not fire onAgentBecameCurrent on an unchanged-version reconnect")
    func recordObservedSkipsBecameCurrentWhenUnchanged() throws {
        let bundled = try #require(KernovaMacOSAgentInfo.bundledVersion)
        // Same version as last seen → the became-current guard short-circuits,
        // so a disk mounted to run uninstall.command is never yanked out by a
        // same-version reconnect — even when an OS-version change makes the
        // write itself go through.
        let instance = makeMacOSInstanceWithAgentInstalled(lastSeen: bundled)
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }
        var fired = 0
        instance.onAgentBecameCurrent = { fired += 1 }

        instance.recordObservedAgentInfo(
            ObservedAgentInfo(agentVersion: bundled, osVersion: "Version 26.0 (Build 25A123)"))

        #expect(fired == 0)
        #expect(instance.configuration.lastSeenGuestOSVersion == "Version 26.0 (Build 25A123)")
    }

    @Test("recordObservedAgentInfo cancels the watchdog and clears expected-missing")
    func recordObservedClearsWatchdogState() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        instance.agentExpectedButMissing = true
        instance.startAgentPostStartWatchdog(grace: .seconds(10))

        instance.recordObservedAgentInfo(ObservedAgentInfo(agentVersion: "0.9.2", osVersion: nil))

        #expect(instance.agentExpectedButMissing == false)
        // Re-arming after the cancel must succeed (proves the prior task
        // was cancelled — the idempotency guard does not block this).
        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)
        await instance.agentPostStartTaskForTesting?.value
        #expect(instance.agentExpectedButMissing == true)
    }

    // MARK: - guestOSVersionDisplay

    @Test("guestOSVersionDisplay reduces an operatingSystemVersionString report to its version")
    func guestOSVersionDisplayReducesDisplayStringReport() {
        let instance = makeMacOSInstanceWithAgentInstalled(
            lastSeenGuestOSVersion: "Version 26.0 (Build 25A123)")
        #expect(instance.guestOSVersionDisplay == "26.0")
    }

    @Test("guestOSVersionDisplay reduces a guest-localized report the same way")
    func guestOSVersionDisplayReducesLocalizedReport() {
        let instance = makeMacOSInstanceWithAgentInstalled(
            lastSeenGuestOSVersion: "Versión 26.0 (Compilación 25A123)")
        #expect(instance.guestOSVersionDisplay == "26.0")
    }

    @Test("guestOSVersionDisplay passes the numeric shape through untouched")
    func guestOSVersionDisplayPassthrough() {
        #expect(
            makeMacOSInstanceWithAgentInstalled(lastSeenGuestOSVersion: "26.0")
                .guestOSVersionDisplay == "26.0")
        #expect(
            makeMacOSInstanceWithAgentInstalled(lastSeenGuestOSVersion: "26.0.1")
                .guestOSVersionDisplay == "26.0.1")
    }

    @Test("guestOSVersionDisplay passes a report holding no digits through untouched")
    func guestOSVersionDisplayNoDigitsPassthrough() {
        let instance = makeMacOSInstanceWithAgentInstalled(lastSeenGuestOSVersion: "macOS")
        #expect(instance.guestOSVersionDisplay == "macOS")
    }

    @Test("guestOSVersionDisplay is nil for nil and empty values, so the row hides")
    func guestOSVersionDisplayUnknown() {
        #expect(makeMacOSInstanceWithAgentInstalled().guestOSVersionDisplay == nil)
        // "" can only come from a hand-edited config.json (the service and
        // recorder both normalize it to nil) but must not render as a blank row.
        #expect(
            makeMacOSInstanceWithAgentInstalled(lastSeenGuestOSVersion: "").guestOSVersionDisplay
                == nil)
    }
}
