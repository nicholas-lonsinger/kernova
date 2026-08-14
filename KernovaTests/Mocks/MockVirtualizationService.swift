import Foundation
@testable import Kernova

/// Mock for `VirtualizationProviding` that sets VM status without real VZ operations.
@MainActor
final class MockVirtualizationService: VirtualizationProviding {
    // MARK: - Call Tracking

    var startCallCount = 0
    var stopCallCount = 0
    var forceStopCallCount = 0
    var pauseCallCount = 0
    var resumeCallCount = 0
    var saveCallCount = 0

    /// The `bootIntoRecovery` argument from the most recent `start` call.
    var lastStartBootIntoRecovery = false

    /// The configuration as it stood when `start` was called, so a caller that
    /// must persist a change *before* the VZ configuration is built can be
    /// asserted on ordering, not just on the final value.
    var configurationAtStart: VMConfiguration?

    /// The status the VM was in when `start` was called.
    ///
    /// The real service refuses a start from a status that fails
    /// ``VMStatus/canStart``; recording it is what lets a caller that hands a
    /// VM off to a boot be asserted on the state it hands over.
    var statusAtStart: VMStatus?

    // MARK: - Error Injection & Recovery

    var startError: (any Error)?
    var stopError: (any Error)?
    var forceStopError: (any Error)?
    var pauseError: (any Error)?
    var resumeError: (any Error)?
    var saveError: (any Error)?

    // MARK: - VirtualizationProviding

    func start(_ instance: VMInstance, bootIntoRecovery: Bool = false) async throws {
        startCallCount += 1
        lastStartBootIntoRecovery = bootIntoRecovery
        configurationAtStart = instance.configuration
        statusAtStart = instance.status
        if let error = startError {
            instance.tearDownSession()
            VirtualizationService.applyLifecycleFailure(
                error, to: instance, transientRestingStatus: .stopped)
            throw error
        }
        instance.status = .running
    }

    func stop(_ instance: VMInstance) throws {
        stopCallCount += 1
        if let error = stopError { throw error }
        instance.resetToStopped()
    }

    func forceStop(_ instance: VMInstance) async throws {
        forceStopCallCount += 1
        if let error = forceStopError { throw error }
        instance.resetToStopped()
    }

    func pause(_ instance: VMInstance) async throws {
        pauseCallCount += 1
        if let error = pauseError {
            instance.status = .error
            instance.errorMessage = error.localizedDescription
            throw error
        }
        instance.status = .paused
    }

    func resume(_ instance: VMInstance) async throws {
        resumeCallCount += 1
        if let error = resumeError {
            instance.tearDownSession()
            VirtualizationService.applyLifecycleFailure(
                error, to: instance, transientRestingStatus: nil)
            throw error
        }
        instance.status = .running
    }

    func save(_ instance: VMInstance) async throws {
        saveCallCount += 1
        // The real service marks the VM `.saving` before tearing the session
        // down and settles the resting status after — so the teardown hook
        // fires while the status still reads as transitioning.
        instance.status = .saving
        if let error = saveError {
            instance.tearDownSession()
            instance.status = .error
            instance.errorMessage = error.localizedDescription
            throw error
        }
        instance.tearDownSession()
        instance.status = .paused
    }
}
