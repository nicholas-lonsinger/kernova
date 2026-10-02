import Foundation

@testable import Kernova

/// Stands in for a `VMSession` during a snapshot capture, modelling VZ's own
/// `state` rather than the capture's intent.
///
/// `pauseIfRunning` and `resumeIfPaused` act on whatever the guest is doing —
/// VZ keeps no record of who paused it — which is the behaviour the capture has
/// to work around, so the mock reproduces it exactly.
actor MockSnapshotSession: VMSnapshotSessionOperating {
    enum GuestState: Sendable {
        case running
        case paused
    }

    /// What the guest is doing, mutated by the calls the capture makes.
    private(set) var guestState: GuestState
    private(set) var calls: [String] = []
    private(set) var savedStateURLs: [URL] = []

    var saveError: (any Error)?

    /// Runs once the state has been written, before the disks are copied — the
    /// seam a test lands a mid-capture guest failure through, so the capture
    /// finds its session gone at exactly the point a real one would.
    private var afterSave: (@Sendable () async -> Void)?

    init(guestState: GuestState) {
        self.guestState = guestState
    }

    func setSaveError(_ error: any Error) {
        saveError = error
    }

    func setAfterSave(_ work: @escaping @Sendable () async -> Void) {
        afterSave = work
    }

    func pauseIfRunning() async throws {
        calls.append("pauseIfRunning")
        guard guestState == .running else { return }
        guestState = .paused
    }

    func resumeIfPaused() async throws {
        calls.append("resumeIfPaused")
        guard guestState == .paused else { return }
        guestState = .running
    }

    /// What `usbDeviceIDs()` answers: the devices on the controller.
    private var controllerDeviceIDs: Set<UUID> = []

    func setUSBDeviceIDs(_ deviceIDs: Set<UUID>) {
        controllerDeviceIDs = deviceIDs
    }

    func usbDeviceIDs() async -> Set<UUID> {
        controllerDeviceIDs
    }

    func saveMachineState(to url: URL) async throws {
        calls.append("saveMachineState")
        savedStateURLs.append(url)
        if let saveError { throw saveError }
        // A stand-in file at the URL, as VZ lays the saved state.
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("saved-state".utf8).write(to: url)
        await afterSave?()
    }

    /// The URLs `restoreMachineState(from:)` was handed, in order.
    private(set) var restoredStateURLs: [URL] = []

    /// Runs once the state has been read, before the guest resumes — the
    /// seam a test lands a change mid-restore through.
    private var afterRestore: (@Sendable () async -> Void)?

    func setAfterRestore(_ work: @escaping @Sendable () async -> Void) {
        afterRestore = work
    }

    private var restoreError: (any Error)?

    func setRestoreError(_ error: any Error) {
        restoreError = error
    }

    func restoreMachineState(from url: URL) async throws {
        calls.append("restoreMachineState")
        restoredStateURLs.append(url)
        if let restoreError { throw restoreError }
        await afterRestore?()
    }

    func resume() async throws {
        calls.append("resume")
        guestState = .running
    }
}
