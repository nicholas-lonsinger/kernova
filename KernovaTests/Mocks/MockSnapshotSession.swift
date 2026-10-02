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

    /// Whether a save lays a stand-in file at the URL it was handed, as VZ
    /// lays the saved state — for a caller that reads the file's presence.
    private let writesStateFile: Bool

    /// Runs once the state has been written, before the disks are copied — the
    /// seam a test lands a mid-capture guest failure through, so the capture
    /// finds its session gone at exactly the point a real one would.
    private var afterSave: (@Sendable () async -> Void)?

    init(guestState: GuestState, writesStateFile: Bool = false) {
        self.guestState = guestState
        self.writesStateFile = writesStateFile
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

    /// Device UUIDs `detachUSBDevice(uuid:)` was asked for, in order.
    private(set) var detachedUSBDeviceIDs: [UUID] = []
    var detachError: (any Error)?

    /// The one device `detachError` answers for, `nil` for every one of them.
    private var detachErrorDeviceID: UUID?

    /// Fails the detach of `deviceID`, or of every device when none is named —
    /// which is what separates a sweep that throws part-way from one that
    /// throws on its first device.
    func setDetachError(_ error: any Error, forDeviceID deviceID: UUID? = nil) {
        detachError = error
        detachErrorDeviceID = deviceID
    }

    /// Runs as each detach begins, before it can throw — the moment a sweep
    /// has committed to taking that device off.
    private var beforeDetach: (@Sendable (UUID) async -> Void)?

    func setBeforeDetach(_ work: @escaping @Sendable (UUID) async -> Void) {
        beforeDetach = work
    }

    func detachUSBDevice(uuid: UUID) async throws {
        calls.append("detachUSBDevice")
        await beforeDetach?(uuid)
        if let detachError, detachErrorDeviceID == nil || detachErrorDeviceID == uuid {
            throw detachError
        }
        detachedUSBDeviceIDs.append(uuid)
    }

    func saveMachineState(to url: URL) async throws {
        calls.append("saveMachineState")
        savedStateURLs.append(url)
        if let saveError { throw saveError }
        if writesStateFile {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("saved-state".utf8).write(to: url)
        }
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

    func restoreMachineState(from url: URL) async throws {
        calls.append("restoreMachineState")
        restoredStateURLs.append(url)
        await afterRestore?()
    }

    func resume() async throws {
        calls.append("resume")
        guestState = .running
    }
}
