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
        guard instance.status.canStart else {
            throw VirtualizationError.invalidStateTransition(from: instance.status, action: "start")
        }

        instance.status = .starting

        do {
            if instance.hasSaveFile {
                try await restoreOrColdBoot(instance)
            } else {
                let vzConfig = try configBuilder.build(
                    from: instance.configuration,
                    bundleURL: instance.bundleURL
                )
                let vm = VZVirtualMachine(configuration: vzConfig)
                instance.virtualMachine = vm
                instance.setupDelegate()
                try await vm.start()
            }

            instance.status = .running
            Self.logger.info("Started VM '\(instance.name)'")
        } catch {
            instance.status = .error
            instance.errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Stop

    /// Requests a graceful ACPI shutdown of the virtual machine.
    func stop(_ instance: VMInstance) throws {
        // Cold-paused: no live VM, just discard the save file
        if instance.isColdPaused {
            try? FileManager.default.removeItem(at: instance.saveFileURL)
            instance.status = .stopped
            Self.logger.info("Discarded saved state for VM '\(instance.name)'")
            return
        }

        guard instance.status.canStop, let vm = instance.virtualMachine else {
            throw VirtualizationError.invalidStateTransition(from: instance.status, action: "stop")
        }

        try vm.requestStop()
        Self.logger.info("Requested stop for VM '\(instance.name)'")
    }

    /// Immediately terminates the virtual machine.
    func forceStop(_ instance: VMInstance) async throws {
        // Cold-paused: no live VM, just discard the save file
        if instance.isColdPaused {
            try? FileManager.default.removeItem(at: instance.saveFileURL)
            instance.status = .stopped
            Self.logger.info("Discarded saved state for VM '\(instance.name)'")
            return
        }

        guard let vm = instance.virtualMachine else {
            throw VirtualizationError.noVirtualMachine
        }

        try await vm.stop()
        instance.status = .stopped
        instance.virtualMachine = nil
        Self.logger.info("Force-stopped VM '\(instance.name)'")
    }

    // MARK: - Pause / Resume

    /// Pauses the virtual machine.
    func pause(_ instance: VMInstance) async throws {
        guard instance.status.canPause, let vm = instance.virtualMachine else {
            throw VirtualizationError.invalidStateTransition(from: instance.status, action: "pause")
        }

        try await vm.pause()
        instance.status = .paused
        Self.logger.info("Paused VM '\(instance.name)'")
    }

    /// Resumes a paused virtual machine.
    ///
    /// Handles two cases:
    /// - **Hot resume**: VM is in memory — calls `vm.resume()` directly.
    /// - **Cold resume**: VM state is on disk only — rebuilds the VM and restores from save file.
    func resume(_ instance: VMInstance) async throws {
        guard instance.status.canResume else {
            throw VirtualizationError.invalidStateTransition(from: instance.status, action: "resume")
        }

        do {
            if let vm = instance.virtualMachine {
                // Hot resume — VM is already in memory
                try await vm.resume()
                instance.status = .running

                if instance.hasSaveFile {
                    try? FileManager.default.removeItem(at: instance.saveFileURL)
                }
            } else if instance.hasSaveFile {
                // Cold resume — rebuild VM from disk state
                try await restoreOrColdBoot(instance)
                instance.status = .running
            } else {
                throw VirtualizationError.noSaveFile
            }

            Self.logger.info("Resumed VM '\(instance.name)'")
        } catch {
            instance.status = .error
            instance.errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Save / Restore

    /// Saves the current VM state to disk (pause + snapshot).
    func save(_ instance: VMInstance) async throws {
        guard instance.status.canSave, let vm = instance.virtualMachine else {
            throw VirtualizationError.invalidStateTransition(from: instance.status, action: "save")
        }

        instance.status = .saving

        // Pause first if running
        if vm.state == .running {
            try await vm.pause()
        }

        try await saveMachineState(vm, to: instance.saveFileURL)
        instance.status = .paused
        Self.logger.info("Saved state for VM '\(instance.name)'")
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
        try await restoreMachineState(vm, from: instance.saveFileURL)
        try await vm.resume()
        instance.status = .running

        // Remove save file after successful restore
        try? FileManager.default.removeItem(at: instance.saveFileURL)
        Self.logger.info("Restored state for VM '\(instance.name)'")
    }

    // MARK: - Private Helpers

    /// Builds a `VZVirtualMachine`, restores from a save file, and resumes.
    /// On restore failure, deletes the stale save file and falls back to a cold boot.
    private func restoreOrColdBoot(_ instance: VMInstance) async throws {
        let vzConfig = try configBuilder.build(
            from: instance.configuration,
            bundleURL: instance.bundleURL
        )

        let vm = VZVirtualMachine(configuration: vzConfig)
        instance.virtualMachine = vm
        instance.setupDelegate()

        do {
            instance.status = .restoring
            try await restoreMachineState(vm, from: instance.saveFileURL)
            try await vm.resume()
            try? FileManager.default.removeItem(at: instance.saveFileURL)
        } catch {
            Self.logger.warning(
                "Restore failed for VM '\(instance.name)', falling back to cold boot: \(error.localizedDescription)"
            )
            try? FileManager.default.removeItem(at: instance.saveFileURL)

            // Create a fresh VZVirtualMachine since the previous one may be in a bad state
            let freshVM = VZVirtualMachine(configuration: vzConfig)
            instance.virtualMachine = freshVM
            instance.setupDelegate()
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
