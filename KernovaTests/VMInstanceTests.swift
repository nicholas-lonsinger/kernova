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

    @Test("PreparingOperation cancelLabel and cancelAlertTitle")
    func preparingOperationLabels() {
        #expect(VMInstance.PreparingOperation.cloning.cancelLabel == "Cancel Clone")
        #expect(VMInstance.PreparingOperation.cloning.cancelAlertTitle == "Cancel Clone?")
        #expect(VMInstance.PreparingOperation.importing.cancelLabel == "Cancel Import")
        #expect(VMInstance.PreparingOperation.importing.cancelAlertTitle == "Cancel Import?")
    }
}
