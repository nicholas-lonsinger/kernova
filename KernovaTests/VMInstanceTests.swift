import Testing
import Foundation
import AppKit
@testable import Kernova

@Suite("VMInstance Tests")
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

    @Test("tearDownSession clears pipes and virtualMachine without changing status")
    func tearDownSessionPreservesStatus() {
        let instance = makeInstance(status: .running)
        instance.serialInputPipe = Pipe()
        instance.serialOutputPipe = Pipe()

        instance.tearDownSession()

        #expect(instance.status == .running)
        #expect(instance.virtualMachine == nil)
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
        #expect(instance.virtualMachine == nil)
        #expect(instance.serialInputPipe == nil)
        #expect(instance.serialOutputPipe == nil)
    }

    // MARK: - resetToStopped

    @Test("resetToStopped sets status to stopped and clears virtualMachine")
    func resetToStopped() {
        let instance = makeInstance(status: .running)
        // Simulate having a VM reference (we can't create a real VZVirtualMachine)
        #expect(instance.status == .running)

        instance.resetToStopped()

        #expect(instance.status == .stopped)
        #expect(instance.virtualMachine == nil)
    }

    @Test("resetToStopped is idempotent when already stopped")
    func resetToStoppedIdempotent() {
        let instance = makeInstance(status: .stopped)
        instance.resetToStopped()
        #expect(instance.status == .stopped)
        #expect(instance.virtualMachine == nil)
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

    @Test("isColdPaused is true when paused with no virtualMachine")
    func isColdPausedTrue() {
        let instance = makeInstance(status: .paused)
        #expect(instance.virtualMachine == nil)
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
        #expect(instance.virtualMachine == nil)
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
        let bundle = IPSWBundle(url: IPSWService.resumeBundleURL(for: destination))
        try bundle.prepareForFreshDownload(
            with: IPSWDownloadMetadata(
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

    @Test("StartAction labels match what each variant performs")
    func startActionLabels() {
        #expect(VMInstance.StartAction.start.label == "Start")
        #expect(VMInstance.StartAction.install.label == "Install")
        #expect(VMInstance.StartAction.resumeInstall.label == "Resume Install")
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

    // MARK: - applyLivePolicy guards

    @Test("applyLivePolicy is a no-op when the VM is stopped")
    func applyLivePolicyNoopWhenStopped() {
        let instance = makeInstance(status: .stopped)
        let oldConfig = instance.configuration
        var newConfig = oldConfig
        newConfig.agentLogForwardingEnabled = true

        // No virtualMachine set — applyLivePolicy must early-exit cleanly.
        instance.applyLivePolicy(oldConfig: oldConfig, newConfig: newConfig)

        #expect(instance.vsockLogListenerHost == nil)
        #expect(instance.vsockClipboardListenerHost == nil)
    }

    @Test("applyLivePolicy is a no-op when no hot fields changed")
    func applyLivePolicyNoopWithoutDiff() {
        let instance = makeInstance(status: .running)
        let config = instance.configuration

        // Same on both sides — no listener changes should occur. Without a
        // virtualMachine the function exits even earlier; this asserts the
        // guard order doesn't crash on equal inputs.
        instance.applyLivePolicy(oldConfig: config, newConfig: config)

        #expect(instance.vsockLogListenerHost == nil)
        #expect(instance.vsockClipboardListenerHost == nil)
    }

    @Test("VMConfiguration.hotToggleFields covers all runtime-editable booleans")
    func hotToggleFieldsCovered() {
        let fields = VMConfiguration.hotToggleFields
        #expect(fields.count == 6)
        #expect(fields.contains(\.agentLogForwardingEnabled))
        #expect(fields.contains(\.clipboardSharingEnabled))
        #expect(fields.contains(\.clipboardPassthroughEnabled))
        #expect(fields.contains(\.serialSocketRelayEnabled))
        #expect(fields.contains(\.agentInstallNudgeDismissed))
        #expect(fields.contains(\.displayAutoResizes))
    }

    // MARK: - Agent Post-Start Watchdog
    //
    // The watchdog flips `agentExpectedButMissing` after a grace period when:
    //   - The guest is macOS,
    //   - `lastSeenAgentVersion` is set (so we have a baseline expectation),
    //   - No `installState` is in progress, and
    //   - No Hello arrives during the grace window.
    // Tests inject a millisecond-scale grace so the suite stays fast.

    /// Builds a macOS VMInstance with a known `lastSeenAgentVersion`.
    ///
    /// The caller is responsible for explicitly clearing the watchdog if needed
    /// across tests.
    private func makeMacOSInstanceWithAgentInstalled(
        lastSeen: String = "0.9.2",
        lastSeenGuestOSVersion: String? = nil,
        installState: MacOSInstallState? = nil
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
        instance.installState = installState
        return instance
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

    @Test("Watchdog is a no-op after a recovery boot")
    func watchdogNoopAfterRecoveryBoot() async throws {
        // Recovery never runs the agent, so its silence proves nothing — the
        // "didn't reconnect" badge would be false and clearing the stored guest
        // OS version would erase a value that is not in doubt.
        let instance = makeMacOSInstanceWithAgentInstalled(
            lastSeenGuestOSVersion: "Version 26.0 (Build 25A123)")

        instance.startAgentPostStartWatchdog(
            afterRecoveryBoot: true, grace: Self.testWatchdogGrace)
        try await Task.sleep(for: Self.testWatchdogGrace * 3)
        #expect(instance.agentExpectedButMissing == false)
        #expect(instance.configuration.lastSeenGuestOSVersion == "Version 26.0 (Build 25A123)")
    }

    @Test("Watchdog is a no-op while macOS install is in progress")
    func watchdogNoopDuringMacOSInstall() async throws {
        // No agent exists during install; no point arming the watchdog.
        let installState = MacOSInstallState(
            hasDownloadStep: true,
            currentPhase: .downloading(.zero)
        )
        let instance = makeMacOSInstanceWithAgentInstalled(installState: installState)

        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)
        try await Task.sleep(for: Self.testWatchdogGrace * 3)
        #expect(instance.agentExpectedButMissing == false)
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

    @Test("guestOSVersionDisplay strips the operatingSystemVersionString lead-in")
    func guestOSVersionDisplayStripsLeadIn() {
        let instance = makeMacOSInstanceWithAgentInstalled(
            lastSeenGuestOSVersion: "Version 26.0 (Build 25A123)")
        #expect(instance.guestOSVersionDisplay == "26.0 (Build 25A123)")
    }

    @Test("guestOSVersionDisplay passes other shapes through untouched")
    func guestOSVersionDisplayPassthrough() {
        let instance = makeMacOSInstanceWithAgentInstalled(lastSeenGuestOSVersion: "26.0")
        #expect(instance.guestOSVersionDisplay == "26.0")
    }

    @Test("guestOSVersionDisplay reads Unknown for nil and empty values")
    func guestOSVersionDisplayUnknown() {
        #expect(makeMacOSInstanceWithAgentInstalled().guestOSVersionDisplay == "Unknown")
        // "" can only come from a hand-edited config.json (the service and
        // recorder both normalize it to nil) but must not render as blank.
        #expect(
            makeMacOSInstanceWithAgentInstalled(lastSeenGuestOSVersion: "").guestOSVersionDisplay
                == "Unknown")
    }
}
