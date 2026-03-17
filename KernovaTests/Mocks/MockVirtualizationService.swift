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
    var restoreCallCount = 0

    // MARK: - Error Injection

    var startError: (any Error)?
    var stopError: (any Error)?
    var forceStopError: (any Error)?
    var pauseError: (any Error)?
    var resumeError: (any Error)?
    var saveError: (any Error)?
    var restoreError: (any Error)?

    // MARK: - VirtualizationProviding

    func start(_ instance: VMInstance) async throws {
        startCallCount += 1
        if let error = startError {
            instance.tearDownSession()
            instance.status = .error
            instance.errorMessage = error.localizedDescription
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
            instance.status = .error
            instance.errorMessage = error.localizedDescription
            throw error
        }
        instance.status = .running
    }

    func save(_ instance: VMInstance) async throws {
        saveCallCount += 1
        if let error = saveError {
            instance.tearDownSession()
            instance.status = .error
            instance.errorMessage = error.localizedDescription
            throw error
        }
        instance.tearDownSession()
        instance.status = .paused
    }

    func restore(_ instance: VMInstance) async throws {
        restoreCallCount += 1
        if let error = restoreError {
            instance.tearDownSession()
            instance.status = .error
            instance.errorMessage = error.localizedDescription
            throw error
        }
        instance.status = .running
    }
}
