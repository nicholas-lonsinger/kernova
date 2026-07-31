import Foundation
import Virtualization
import os

/// Manages VM lifecycle operations: start, stop, pause, resume, save, and restore.
///
/// All operations run on the main actor since `VZVirtualMachine` must be used on the main thread.
@MainActor
final class VirtualizationService {
    private static let logger = Logger(subsystem: "app.kernova", category: "VirtualizationService")

    private let configBuilder = ConfigurationBuilder()

    // MARK: - Start

    /// Starts a virtual machine, optionally restoring from a saved state.
    ///
    /// `bootIntoRecovery` boots into macOS Recovery for this launch only, and
    /// applies to a macOS cold boot alone — no effect on Linux guests or on the
    /// restore-from-save path.
    func start(_ instance: VMInstance, bootIntoRecovery: Bool = false) async throws {
        Self.logger.debug(
            "start: status=\(instance.status.displayName, privacy: .public), hasSaveFile=\(instance.hasSaveFile, privacy: .public), bootIntoRecovery=\(bootIntoRecovery, privacy: .public)"
        )
        guard instance.status.canStart else {
            throw VirtualizationError.invalidStateTransition(from: instance.status, action: "start")
        }

        instance.status = .starting

        do {
            if instance.hasSaveFile {
                try await restoreOrColdBoot(instance)
            } else {
                try await coldBootRetryingLockContention(
                    instance, bootIntoRecovery: bootIntoRecovery)
            }

            instance.status = .running
            // The watchdog flips `agentExpectedButMissing` when a VM that has seen
            // the agent before gets no Hello within the grace period. No-op for
            // fresh VMs (no `lastSeenAgentVersion`) and for Linux.
            instance.startAgentPostStartWatchdog()
            if bootIntoRecovery {
                Self.logger.notice("Started VM '\(instance.name, privacy: .public)' in recovery mode")
            } else {
                Self.logger.notice("Started VM '\(instance.name, privacy: .public)'")
            }
        } catch {
            let nsError = error as NSError
            Self.logger.error(
                "Failed to start VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public) [\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public); underlying: \(Self.underlyingChainDescription(nsError), privacy: .public)]"
            )
            instance.tearDownSession()
            let isTransient = Self.isTransientStartError(error)
            instance.status = isTransient ? .stopped : .error
            instance.errorMessage = isTransient ? nil : error.localizedDescription
            throw error
        }
    }

    // MARK: - Cold Boot

    /// Cold-boots `instance`, retrying with bounded backoff when the start fails on
    /// VZ file-lock contention (see ``isFileLockContention(_:)``).
    ///
    /// A previous `VZVirtualMachine` on the same bundle releases its advisory lock
    /// on the auxiliary-storage and disk-image files only when fully *deallocated*,
    /// which lags `vm.state == .stopped` by more the more guest memory there is to
    /// tear down. No public VZ API observes the release, so gating on state cannot
    /// be airtight; a bounded retry against the ground-truth failure is.
    private func coldBootRetryingLockContention(
        _ instance: VMInstance, bootIntoRecovery: Bool
    ) async throws {
        var attempt = 0
        while true {
            do {
                try await coldBoot(instance, bootIntoRecovery: bootIntoRecovery)
                return
            } catch let startError {
                guard Self.isFileLockContention(startError),
                    let delay = Self.fileLockRetryDelay(forAttempt: attempt)
                else { throw startError }
                attempt += 1
                Self.logger.warning(
                    "Cold boot of '\(instance.name, privacy: .public)' hit file-lock contention; retry \(attempt, privacy: .public) in \(String(describing: delay), privacy: .public)"
                )
                instance.tearDownSession()
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    // Cancelled mid-backoff: surface the original lock failure
                    // rather than leak a `CancellationError` into the status/alert
                    // classification paths, which aren't shaped for it.
                    throw startError
                }
            }
        }
    }

    /// Builds a fresh configuration and `VZVirtualMachine`, wires the session
    /// plumbing, and starts the machine — one cold-boot attempt.
    private func coldBoot(_ instance: VMInstance, bootIntoRecovery: Bool) async throws {
        // Per attempt, not once per start: the lock-contention retry loop tears the
        // session down — releasing these scopes — between attempts.
        instance.openRuntimeFileAccess()
        let result = try await buildConfiguration(for: instance)
        instance.serialInputPipe = result.serialInputPipe
        instance.serialOutputPipe = result.serialOutputPipe
        instance.clipboardInputPipe = result.clipboardInputPipe
        instance.clipboardOutputPipe = result.clipboardOutputPipe
        instance.liveRemovableMedia = result.coldRemovableMedia
        let vm = instance.attachVirtualMachine(from: result.configuration)
        instance.startSerialReading()
        instance.startClipboardService()
        instance.startVsockServices()
        let startOptions = Self.recoveryStartOptions(
            bootIntoRecovery: bootIntoRecovery, guestOS: instance.configuration.guestOS)
        try await startMachine(vm, options: startOptions)
    }

    /// Detects VZ's advisory file-lock contention on a VM's backing files.
    ///
    /// Matches "Failed to lock auxiliary storage" (or the disk-image equivalent):
    /// `.invalidVirtualMachineConfiguration` carrying a POSIX `EAGAIN` underneath,
    /// which is what separates it from a genuinely invalid configuration (same VZ
    /// code, no `EAGAIN`) — matching localized text would be locale-fragile. A
    /// disk-image attach failure arrives wrapped in a `ConfigurationBuilderError`,
    /// so unwrap before matching or the contention retry never fires.
    static func isFileLockContention(_ error: Error) -> Bool {
        if let builderError = error as? ConfigurationBuilderError,
            let underlying = builderError.underlyingAttachError
        {
            return isFileLockContention(underlying)
        }
        let nsError = error as NSError
        guard nsError.domain == VZError.errorDomain,
            VZError.Code(rawValue: nsError.code) == .invalidVirtualMachineConfiguration,
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        else { return false }
        return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(EAGAIN)
    }

    /// Backoff before file-lock-contention cold-boot retry number `attempt`.
    ///
    /// `attempt` is 0-based; returns `nil` once the ~3.75 s budget is exhausted.
    /// Escalates because the holder's teardown time scales with guest memory size.
    static func fileLockRetryDelay(forAttempt attempt: Int) -> Duration? {
        let delays: [Duration] = [
            .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2),
        ]
        guard delays.indices.contains(attempt) else { return nil }
        return delays[attempt]
    }

    /// Builds the one-shot start options for a recovery boot.
    ///
    /// Returns `nil` — a normal boot — unless a recovery boot is requested for a
    /// macOS guest.
    static func recoveryStartOptions(
        bootIntoRecovery: Bool, guestOS: VMGuestOS
    ) -> VZMacOSVirtualMachineStartOptions? {
        guard bootIntoRecovery, guestOS == .macOS else { return nil }
        let options = VZMacOSVirtualMachineStartOptions()
        options.startUpFromMacOSRecovery = true
        return options
    }

    // MARK: - Stop

    /// Requests a graceful ACPI shutdown of the virtual machine.
    func stop(_ instance: VMInstance) throws {
        Self.logger.debug(
            "stop: status=\(instance.status.displayName, privacy: .public), isColdPaused=\(instance.isColdPaused, privacy: .public)"
        )
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

    func forceStop(_ instance: VMInstance) async throws {
        Self.logger.debug(
            "forceStop: status=\(instance.status.displayName, privacy: .public), isColdPaused=\(instance.isColdPaused, privacy: .public)"
        )
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
            Self.logger.error(
                "Failed to pause VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            instance.status = .error
            instance.errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Resumes a paused virtual machine.
    ///
    /// Hot resume when the VM is still in memory; cold resume rebuilds it and
    /// restores from the save file.
    func resume(_ instance: VMInstance) async throws {
        Self.logger.debug(
            "resume: status=\(instance.status.displayName, privacy: .public), hasVM=\(instance.virtualMachine != nil, privacy: .public), hasSaveFile=\(instance.hasSaveFile, privacy: .public)"
        )
        guard instance.status.canResume else {
            throw VirtualizationError.invalidStateTransition(from: instance.status, action: "resume")
        }

        do {
            if let vm = instance.virtualMachine {
                try await vm.resume()
                instance.status = .running
                instance.removeSaveFile()
            } else if instance.hasSaveFile {
                try await restoreOrColdBoot(instance)
                instance.status = .running
            } else {
                throw VirtualizationError.noSaveFile
            }

            Self.logger.notice("Resumed VM '\(instance.name, privacy: .public)'")
        } catch {
            Self.logger.error(
                "Failed to resume VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
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
            if vm.state == .running {
                try await vm.pause()
            }

            try await saveMachineState(vm, to: instance.saveFileURL)
            // No sidecar metadata is needed beside the save file: removable media
            // carry stable UUIDs and storage disks stable virtio block identifiers
            // in `config`, and VZ matches both on restore.
            instance.tearDownSession()
            instance.status = .paused
            Self.logger.notice("Saved state for VM '\(instance.name, privacy: .public)'")
        } catch {
            Self.logger.error(
                "Failed to save VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            instance.tearDownSession()
            instance.status = .error
            instance.errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Error Classification

    /// How far an `NSUnderlyingErrorKey` walk follows the chain — framework
    /// `userInfo` can nest arbitrarily deep, or cyclically.
    private static let maxUnderlyingErrorDepth = 4

    /// Returns `true` when the error is a transient environmental condition (e.g. too many
    /// concurrent VMs) rather than a problem with the VM itself.
    ///
    /// Transient leaves a plain start in `.stopped` and an install in
    /// `.initialBoot`, with no stored message; permanent sets `.error` (red)
    /// and keeps the message for the banner and tooltip.
    static func isTransientStartError(_ error: Error) -> Bool {
        // Checked ahead of the builder-error rule below: contention on a disk image
        // surfaces *as* a builder error and is still transient — the lock holder is
        // a dying VZVirtualMachine that releases it at deallocation.
        if isFileLockContention(error) { return true }

        if error is ConfigurationBuilderError { return false }

        if isVirtualMachineLimitExceeded(error) { return true }

        // Top level only, unlike the limit code: a cancel nested under a failure
        // describes a teardown step, not the failure that has to be classified.
        let nsError = error as NSError
        return nsError.domain == VZError.errorDomain
            && VZError.Code(rawValue: nsError.code) == .operationCancelled
    }

    /// Returns `true` when `error`, or anything within
    /// ``maxUnderlyingErrorDepth`` of its `NSUnderlyingErrorKey` chain, is
    /// `VZError.Code.virtualMachineLimitExceeded`.
    ///
    /// `VZMacOSInstaller.install()` surfaces the cap as `.installationFailed`
    /// carrying the real code underneath, so the top level alone identifies it
    /// on the plain-start path only.
    static func isVirtualMachineLimitExceeded(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth <= maxUnderlyingErrorDepth {
            if nsError.domain == VZError.errorDomain,
                VZError.Code(rawValue: nsError.code) == .virtualMachineLimitExceeded
            {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    /// `domain code` for each error under `error`, bounded by
    /// ``maxUnderlyingErrorDepth``; `"none"` when nothing is nested.
    static func underlyingChainDescription(_ error: NSError) -> String {
        var links: [String] = []
        var current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        while let nsError = current, links.count < maxUnderlyingErrorDepth {
            links.append("\(nsError.domain) \(nsError.code)")
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return links.isEmpty ? "none" : links.joined(separator: " → ")
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
    ///
    /// On restore failure, deletes the stale save file and falls back to a cold boot.
    private func restoreOrColdBoot(_ instance: VMInstance) async throws {
        instance.openRuntimeFileAccess()
        let result = try await buildConfiguration(for: instance)

        instance.serialInputPipe = result.serialInputPipe
        instance.serialOutputPipe = result.serialOutputPipe
        instance.clipboardInputPipe = result.clipboardInputPipe
        instance.clipboardOutputPipe = result.clipboardOutputPipe
        instance.liveRemovableMedia = result.coldRemovableMedia
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

            // A fresh VZVirtualMachine: the previous one may be in a bad state.
            Self.logger.debug("restoreOrColdBoot: falling back to cold boot with fresh VM")
            let freshVM = instance.attachVirtualMachine(from: result.configuration)
            // Re-attach the vsock listener — the previous one referenced the
            // now-dead VM. Idempotent.
            instance.startVsockServices()
            instance.status = .starting
            try await freshVM.start()
        }
    }

    // MARK: - Private Async Wrappers

    /// Starts `vm`, using the options-aware overload only when `options` are supplied.
    ///
    /// `VZVirtualMachine.start(options:completionHandler:)` has no `async` variant,
    /// so it is bridged through a continuation.
    private func startMachine(_ vm: VZVirtualMachine, options: VZVirtualMachineStartOptions?) async throws {
        guard let options else {
            try await vm.start()
            return
        }
        nonisolated(unsafe) let vm = vm
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            vm.start(options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

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
