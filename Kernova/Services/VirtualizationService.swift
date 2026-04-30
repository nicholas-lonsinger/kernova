import Foundation
import Virtualization
import os

/// Manages VM lifecycle operations: start, stop, pause, resume, save, and restore.
///
/// All operations run on the main actor since `VZVirtualMachine` must be used on the main thread.
@MainActor
final class VirtualizationService {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "VirtualizationService")

    private let configBuilder = ConfigurationBuilder()

    // MARK: - Start

    /// Starts a virtual machine, optionally restoring from a saved state.
    func start(_ instance: VMInstance) async throws {
        Self.logger.debug("start: status=\(instance.status.displayName, privacy: .public), hasSaveFile=\(instance.hasSaveFile, privacy: .public)")
        guard instance.status.canStart else {
            throw VirtualizationError.invalidStateTransition(from: instance.status, action: "start")
        }

        instance.status = .starting

        do {
            if instance.hasSaveFile {
                try await restoreOrColdBoot(instance)
            } else {
                let result = try await buildConfiguration(for: instance)
                instance.serialInputPipe = result.serialInputPipe
                instance.serialOutputPipe = result.serialOutputPipe
                instance.clipboardInputPipe = result.clipboardInputPipe
                instance.clipboardOutputPipe = result.clipboardOutputPipe
                let vm = instance.attachVirtualMachine(from: result.configuration)
                instance.startSerialReading()
                instance.startClipboardService()
                instance.startVsockServices()
                try await vm.start()
            }

            instance.status = .running
            Self.logger.notice("Started VM '\(instance.name, privacy: .public)'")
        } catch {
            Self.logger.error("Failed to start VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            instance.tearDownSession()
            instance.status = Self.isTransientStartError(error) ? .stopped : .error
            instance.errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Stop

    /// Requests a graceful ACPI shutdown of the virtual machine.
    func stop(_ instance: VMInstance) throws {
        Self.logger.debug("stop: status=\(instance.status.displayName, privacy: .public), isColdPaused=\(instance.isColdPaused, privacy: .public)")
        // Cold-paused: no live VM, just discard the save file
        if instance.isColdPaused {
            instance.removeSaveFile()
            instance.status = .stopped
            Self.logger.notice("Discarded saved state for VM '\(instance.name, privacy: .public)'")
            return
        }

        guard instance.status.canStop, let vm = instance.virtualMachine else {
            throw VirtualizationError.invalidStateTransition(from: instance.status, action: "stop")
        }

        try vm.requestStop()
        Self.logger.notice("Requested stop for VM '\(instance.name, privacy: .public)'")
    }

    /// Immediately terminates the virtual machine.
    func forceStop(_ instance: VMInstance) async throws {
        Self.logger.debug("forceStop: status=\(instance.status.displayName, privacy: .public), isColdPaused=\(instance.isColdPaused, privacy: .public)")
        // Cold-paused: no live VM, just discard the save file
        if instance.isColdPaused {
            instance.removeSaveFile()
            instance.status = .stopped
            Self.logger.notice("Discarded saved state for VM '\(instance.name, privacy: .public)'")
            return
        }

        guard let vm = instance.virtualMachine else {
            throw VirtualizationError.noVirtualMachine
        }

        try await vm.stop()
        instance.resetToStopped()
        Self.logger.notice("Force-stopped VM '\(instance.name, privacy: .public)'")
    }

    // MARK: - Pause / Resume

    /// Pauses the virtual machine.
    func pause(_ instance: VMInstance) async throws {
        Self.logger.debug("pause: status=\(instance.status.displayName, privacy: .public)")
        guard instance.status.canPause, let vm = instance.virtualMachine else {
            throw VirtualizationError.invalidStateTransition(from: instance.status, action: "pause")
        }

        do {
            try await vm.pause()
            instance.status = .paused
            Self.logger.notice("Paused VM '\(instance.name, privacy: .public)'")
        } catch {
            Self.logger.error("Failed to pause VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            instance.status = .error
            instance.errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Resumes a paused virtual machine.
    ///
    /// Handles two cases:
    /// - **Hot resume**: VM is in memory — calls `vm.resume()` directly.
    /// - **Cold resume**: VM state is on disk only — rebuilds the VM and restores from save file.
    func resume(_ instance: VMInstance) async throws {
        Self.logger.debug("resume: status=\(instance.status.displayName, privacy: .public), hasVM=\(instance.virtualMachine != nil, privacy: .public), hasSaveFile=\(instance.hasSaveFile, privacy: .public)")
        guard instance.status.canResume else {
            throw VirtualizationError.invalidStateTransition(from: instance.status, action: "resume")
        }

        do {
            if let vm = instance.virtualMachine {
                // Hot resume — VM is already in memory
                try await vm.resume()
                instance.status = .running
                instance.removeSaveFile()
            } else if instance.hasSaveFile {
                // Cold resume — rebuild VM from disk state
                try await restoreOrColdBoot(instance)
                instance.status = .running
            } else {
                throw VirtualizationError.noSaveFile
            }

            Self.logger.notice("Resumed VM '\(instance.name, privacy: .public)'")
        } catch {
            Self.logger.error("Failed to resume VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            instance.tearDownSession()
            instance.status = .error
            instance.errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Save / Restore

    /// Saves the current VM state to disk (pause + snapshot).
    func save(_ instance: VMInstance) async throws {
        Self.logger.debug("save: status=\(instance.status.displayName, privacy: .public)")
        guard instance.status.canSave, let vm = instance.virtualMachine else {
            throw VirtualizationError.invalidStateTransition(from: instance.status, action: "save")
        }

        instance.status = .saving

        do {
            // Pause first if running
            if vm.state == .running {
                try await vm.pause()
            }

            try await saveMachineState(vm, to: instance.saveFileURL)
            instance.tearDownSession()
            instance.status = .paused
            Self.logger.notice("Saved state for VM '\(instance.name, privacy: .public)'")
        } catch {
            Self.logger.error("Failed to save VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            instance.tearDownSession()
            instance.status = .error
            instance.errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Restores a VM from a saved state file.
    func restore(_ instance: VMInstance) async throws {
        guard let vm = instance.virtualMachine else {
            throw VirtualizationError.noVirtualMachine
        }

        guard instance.hasSaveFile else {
            throw VirtualizationError.noSaveFile
        }

        instance.status = .restoring

        do {
            try await restoreMachineState(vm, from: instance.saveFileURL)
            try await vm.resume()
            instance.status = .running

            // Remove save file after successful restore
            instance.removeSaveFile()
            Self.logger.notice("Restored state for VM '\(instance.name, privacy: .public)'")
        } catch {
            Self.logger.error("Failed to restore VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            instance.tearDownSession()
            instance.status = .error
            instance.errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Error Classification

    /// Returns `true` when the error is a transient environmental condition (e.g. too many
    /// concurrent VMs) rather than a problem with the VM itself. Transient errors leave the
    /// VM in `.stopped` so the indicator stays grey; permanent errors set `.error` (red).
    static func isTransientStartError(_ error: Error) -> Bool {
        if error is ConfigurationBuilderError { return false }

        let nsError = error as NSError
        guard nsError.domain == VZError.errorDomain else { return false }

        switch VZError.Code(rawValue: nsError.code) {
        case .virtualMachineLimitExceeded, .operationCancelled:
            return true
        default:
            return false
        }
    }

    // MARK: - Private Helpers

    /// Builds a VZ configuration off the main actor to avoid blocking the UI.
    private func buildConfiguration(for instance: VMInstance) async throws -> ConfigurationBuilder.BuildResult {
        let builder = configBuilder
        let config = instance.configuration
        let bundleURL = instance.bundleURL
        return try await Task.detached {
            try builder.build(from: config, bundleURL: bundleURL)
        }.value
    }

    /// Builds a `VZVirtualMachine`, restores from a save file, and resumes.
    /// On restore failure, deletes the stale save file and falls back to a cold boot.
    private func restoreOrColdBoot(_ instance: VMInstance) async throws {
        let result = try await buildConfiguration(for: instance)

        instance.serialInputPipe = result.serialInputPipe
        instance.serialOutputPipe = result.serialOutputPipe
        instance.clipboardInputPipe = result.clipboardInputPipe
        instance.clipboardOutputPipe = result.clipboardOutputPipe
        let vm = instance.attachVirtualMachine(from: result.configuration)
        instance.startSerialReading()
        instance.startClipboardService()
        instance.startVsockServices()

        Self.logger.debug("restoreOrColdBoot: attempting restore from save file")
        do {
            instance.status = .restoring
            try await restoreMachineState(vm, from: instance.saveFileURL)
            try await vm.resume()
            instance.removeSaveFile()
        } catch {
            Self.logger.warning(
                "Restore failed for VM '\(instance.name, privacy: .public)', falling back to cold boot: \(error.localizedDescription, privacy: .public)"
            )
            instance.removeSaveFile()

            // Create a fresh VZVirtualMachine since the previous one may be in a bad state
            Self.logger.debug("restoreOrColdBoot: falling back to cold boot with fresh VM")
            let freshVM = instance.attachVirtualMachine(from: result.configuration)
            // Re-attach vsock listener to the fresh VM's socket device — the
            // previous listener referenced the now-dead VM. Idempotent.
            instance.startVsockServices()
            instance.status = .starting
            try await freshVM.start()
        }
    }

    // MARK: - Private Async Wrappers

    private func saveMachineState(_ vm: VZVirtualMachine, to url: URL) async throws {
        nonisolated(unsafe) let vm = vm
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            vm.saveMachineStateTo(url: url) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func restoreMachineState(_ vm: VZVirtualMachine, from url: URL) async throws {
        nonisolated(unsafe) let vm = vm
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            vm.restoreMachineStateFrom(url: url) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

// MARK: - VirtualizationProviding

extension VirtualizationService: VirtualizationProviding {}

// MARK: - Errors

enum VirtualizationError: LocalizedError {
    case invalidStateTransition(from: VMStatus, action: String)
    case noVirtualMachine
    case noSaveFile

    var errorDescription: String? {
        switch self {
        case .invalidStateTransition(let status, let action):
            "Cannot \(action) VM in \(status.displayName) state."
        case .noVirtualMachine:
            "No virtual machine instance is available."
        case .noSaveFile:
            "No saved state file found."
        }
    }
}
