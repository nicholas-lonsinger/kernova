import Testing
import Foundation
import SwiftUI
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

    // MARK: - canShowSerialConsole

    @Test("canShowSerialConsole is false when running without a virtual machine")
    func canShowSerialConsoleFalseWithoutVM() {
        let instance = makeInstance(status: .running)
        #expect(instance.virtualMachine == nil)
        #expect(instance.canShowSerialConsole == false)
    }

    @Test("canShowSerialConsole is false when stopped")
    func canShowSerialConsoleFalseWhenStopped() {
        let instance = makeInstance(status: .stopped)
        #expect(instance.canShowSerialConsole == false)
    }

    @Test("canShowSerialConsole is false for cold-paused VM")
    func canShowSerialConsoleFalseWhenColdPaused() {
        let instance = makeInstance(status: .paused)
        #expect(instance.isColdPaused == true)
        #expect(instance.canShowSerialConsole == false)
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

    @Test("serialOutputText starts empty")
    func serialOutputTextStartsEmpty() {
        let instance = makeInstance()
        #expect(instance.serialOutputText.isEmpty)
    }

    @Test("sendSerialInput writes to input pipe")
    func sendSerialInputWritesToPipe() {
        let instance = makeInstance()
        let pipe = Pipe()
        instance.serialInputPipe = pipe

        instance.sendSerialInput("hello")

        let data = pipe.fileHandleForReading.availableData
        #expect(String(data: data, encoding: .utf8) == "hello")
    }

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

    @Test("statusDisplayColor returns orange when cold-paused")
    func statusDisplayColorColdPaused() {
        let instance = makeInstance(status: .paused)
        #expect(instance.isColdPaused == true)
        #expect(instance.statusDisplayColor == .orange)
    }

    @Test("statusDisplayColor delegates to status.statusColor for non-paused states")
    func statusDisplayColorDelegates() {
        for status in [VMStatus.stopped, .running, .starting, .saving, .restoring, .installing, .error] {
            let instance = makeInstance(status: status)
            #expect(instance.statusDisplayColor == status.statusColor)
        }
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

    @Test("statusDisplayColor returns orange when isPreparing")
    func statusDisplayColorPreparing() {
        let instance = makeInstance()
        let task = Task {}
        defer { task.cancel() }
        instance.preparingState = VMInstance.PreparingState(operation: .cloning, task: task)
        #expect(instance.statusDisplayColor == .orange)
    }

    @Test("statusToolTip returns preparing label when isPreparing")
    func statusToolTipPreparing() {
        let instance = makeInstance()
        let task = Task {}
        defer { task.cancel() }
        instance.preparingState = VMInstance.PreparingState(operation: .cloning, task: task)
        #expect(instance.statusToolTip == "Cloning\u{2026}")
    }

    // MARK: - Cached Disk Usage

    @Test("cachedDiskUsageBytes starts nil and becomes non-nil after refreshDiskUsage")
    func cachedDiskUsageRefresh() async throws {
        let instance = makeInstance()

        // Create the bundle directory and a fake disk image so there's something to measure
        try FileManager.default.createDirectory(
            at: instance.bundleURL,
            withIntermediateDirectories: true
        )
        let diskData = Data(repeating: 0xAB, count: 4096)
        try diskData.write(to: instance.diskImageURL)
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }

        #expect(instance.cachedDiskUsageBytes == nil)

        await instance.refreshDiskUsage()

        #expect(instance.cachedDiskUsageBytes != nil)
        #expect(instance.cachedDiskUsageBytes! > 0)
    }

    @Test("cachedDiskUsageBytes remains nil when disk image does not exist")
    func cachedDiskUsageNilForMissingFile() async {
        let instance = makeInstance()

        #expect(instance.cachedDiskUsageBytes == nil)

        await instance.refreshDiskUsage()

        #expect(instance.cachedDiskUsageBytes == nil)
    }

    @Test("PreparingOperation cancelLabel and cancelAlertTitle")
    func preparingOperationLabels() {
        #expect(VMInstance.PreparingOperation.cloning.cancelLabel == "Cancel Clone")
        #expect(VMInstance.PreparingOperation.cloning.cancelAlertTitle == "Cancel Clone?")
        #expect(VMInstance.PreparingOperation.importing.cancelLabel == "Cancel Import")
        #expect(VMInstance.PreparingOperation.importing.cancelAlertTitle == "Cancel Import?")
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

    @Test("VMConfiguration.hotToggleFields covers both runtime-editable booleans")
    func hotToggleFieldsCovered() {
        let fields = VMConfiguration.hotToggleFields
        #expect(fields.count == 2)
        #expect(fields.contains(\.agentLogForwardingEnabled))
        #expect(fields.contains(\.clipboardSharingEnabled))
    }

    // MARK: - Agent Post-Start Watchdog
    //
    // The watchdog flips `agentExpectedButMissing` after a grace period when:
    //   - The guest is macOS,
    //   - `lastSeenAgentVersion` is set (so we have a baseline expectation),
    //   - No `installState` is in progress, and
    //   - No Hello arrives during the grace window.
    // Tests inject a millisecond-scale grace so the suite stays fast.

    /// Builds a macOS VMInstance with a known `lastSeenAgentVersion`. The
    /// caller is responsible for explicitly clearing the watchdog if needed
    /// across tests.
    private func makeMacOSInstanceWithAgentInstalled(
        lastSeen: String = "0.9.2",
        installState: MacOSInstallState? = nil
    ) -> VMInstance {
        var config = VMConfiguration(
            name: "macOS Watchdog Test",
            guestOS: .macOS,
            bootMode: .macOS
        )
        config.lastSeenAgentVersion = lastSeen
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL, status: .running)
        instance.installState = installState
        return instance
    }

    @Test("Watchdog flips agentExpectedButMissing when no Hello arrives in the grace window")
    func watchdogFiresWhenSilent() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        instance.startAgentPostStartWatchdog(grace: .milliseconds(50))

        // Wait past grace; the watchdog runs as a Task so we need to yield.
        try await waitUntil(timeout: .seconds(2)) {
            instance.agentExpectedButMissing
        }
        #expect(instance.agentExpectedButMissing == true)
        #expect(instance.agentStatus == .expectedMissing(expected: "0.9.2"))
    }

    @Test("Cancelling the watchdog before grace prevents firing")
    func watchdogCancelledStaysQuiet() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        instance.startAgentPostStartWatchdog(grace: .milliseconds(200))

        // Cancel well before the grace elapses — the timer task must not
        // flip the flag after cancellation.
        instance.cancelAgentPostStartWatchdog()
        try await Task.sleep(for: .milliseconds(400))
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

        instance.startAgentPostStartWatchdog(grace: .milliseconds(50))
        try await Task.sleep(for: .milliseconds(200))
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

        instance.startAgentPostStartWatchdog(grace: .milliseconds(50))
        try await Task.sleep(for: .milliseconds(200))
        #expect(instance.agentExpectedButMissing == false)
    }

    @Test("Watchdog is a no-op while macOS install is in progress")
    func watchdogNoopDuringMacOSInstall() async throws {
        // No agent exists during install; no point arming the watchdog.
        let installState = MacOSInstallState(
            hasDownloadStep: true,
            currentPhase: .downloading(.zero)
        )
        let instance = makeMacOSInstanceWithAgentInstalled(installState: installState)

        instance.startAgentPostStartWatchdog(grace: .milliseconds(50))
        try await Task.sleep(for: .milliseconds(200))
        #expect(instance.agentExpectedButMissing == false)
    }

    @Test("startAgentPostStartWatchdog is idempotent when already armed")
    func watchdogIdempotent() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        instance.startAgentPostStartWatchdog(grace: .milliseconds(200))
        // Second call must not replace the in-flight task with a fresh one
        // (which would defer firing). Asking with a much smaller grace also
        // shouldn't take effect — we keep the original timer.
        instance.startAgentPostStartWatchdog(grace: .milliseconds(50))

        // Wait past the *shorter* grace but not the original. If the second
        // call had taken effect, the flag would be true here.
        try await Task.sleep(for: .milliseconds(120))
        #expect(instance.agentExpectedButMissing == false)
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
        instance.startAgentPostStartWatchdog(grace: .milliseconds(50))
        try await waitUntil(timeout: .seconds(2)) {
            instance.agentExpectedButMissing
        }
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

    // MARK: - recordObservedAgentVersion

    @Test("recordObservedAgentVersion persists when the version changes")
    func recordObservedPersistsOnChange() {
        let instance = makeMacOSInstanceWithAgentInstalled(lastSeen: "0.9.0")
        var savedConfig: VMConfiguration?
        instance.onConfigurationDidChange = { savedConfig = $0.configuration }

        instance.recordObservedAgentVersion("0.9.2")

        #expect(instance.configuration.lastSeenAgentVersion == "0.9.2")
        #expect(savedConfig?.lastSeenAgentVersion == "0.9.2")
    }

    @Test("recordObservedAgentVersion populates lastSeenAgentVersion for fresh VMs")
    func recordObservedSetsFromNil() {
        // Simulates the very first time an agent connects to a fresh VM —
        // the persisted field starts nil and the observer must seed it.
        let config = VMConfiguration(name: "Fresh", guestOS: .macOS, bootMode: .macOS)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL, status: .running)
        var saveCount = 0
        instance.onConfigurationDidChange = { _ in saveCount += 1 }

        instance.recordObservedAgentVersion("0.9.0")

        #expect(instance.configuration.lastSeenAgentVersion == "0.9.0")
        #expect(saveCount == 1)
    }

    @Test("recordObservedAgentVersion does not persist when the version is unchanged")
    func recordObservedSkipsRedundantWrites() {
        let instance = makeMacOSInstanceWithAgentInstalled(lastSeen: "0.9.2")
        var saveCount = 0
        instance.onConfigurationDidChange = { _ in saveCount += 1 }

        instance.recordObservedAgentVersion("0.9.2")
        instance.recordObservedAgentVersion("0.9.2")

        // Two same-version Hellos must not produce a single disk write.
        // Storage churn would re-fire VMDirectoryWatcher reconcile on every
        // heartbeat-driven reconnect.
        #expect(saveCount == 0)
    }

    @Test("recordObservedAgentVersion cancels the watchdog and clears expected-missing")
    func recordObservedClearsWatchdogState() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        instance.agentExpectedButMissing = true
        instance.startAgentPostStartWatchdog(grace: .seconds(10))

        instance.recordObservedAgentVersion("0.9.2")

        #expect(instance.agentExpectedButMissing == false)
        // Re-arming with a tiny grace must succeed (proves the prior task
        // was cancelled — the idempotency guard does not block this).
        instance.startAgentPostStartWatchdog(grace: .milliseconds(50))
        try await waitUntil(timeout: .seconds(2)) {
            instance.agentExpectedButMissing
        }
    }
}
