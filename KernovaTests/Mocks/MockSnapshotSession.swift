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

    func saveMachineState(to url: URL) async throws {
        calls.append("saveMachineState")
        savedStateURLs.append(url)
        if let saveError { throw saveError }
        await afterSave?()
    }
}
