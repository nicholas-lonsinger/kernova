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
}
