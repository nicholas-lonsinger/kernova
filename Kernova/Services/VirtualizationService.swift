import Foundation
import Virtualization
import os

/// Manages VM lifecycle operations: start, stop, pause, resume, save, and restore.
///
/// Stays on the main actor because it mutates `VMInstance`; every
/// `VZVirtualMachine` touch goes through the instance's `VMSession`, the VM's
/// own isolation domain on its private queue.
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
                try await restoreFromSaveFile(instance)
            } else {
                try await coldBootRetryingLockContention(
                    instance, bootIntoRecovery: bootIntoRecovery)
            }

            instance.status = .running
            // Activation waits for `.running`: VZ documents runtime attachment
            // swapping for a running VM, and a boot or restore that came up
            // detached is reconciled here.
            instance.networkAttachmentCoordinator?.activate()
            // The watchdog flips `agentExpectedButMissing` when a VM that has seen
            // the agent before gets no Hello within the grace period. No-op for
            // fresh VMs (no `lastSeenAgentVersion`), for Linux, and for recovery
            // boots, which never run the agent.
            instance.startAgentPostStartWatchdog()
            if bootIntoRecovery {
                Self.logger.notice("Started VM '\(instance.name, privacy: .public)' in recovery mode")
            } else {
                Self.logger.notice("Started VM '\(instance.name, privacy: .public)'")
            }
        } catch {
            // A restore failure already logged itself with the full error chain.
            if !Self.isRestoreFailure(error) {
                let nsError = error as NSError
                Self.logger.error(
                    "Failed to start VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public) [\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public); underlying: \(Self.underlyingChainDescription(nsError), privacy: .public)]"
                )
            }
            instance.tearDownSession()
            Self.applyLifecycleFailure(error, to: instance, transientRestingStatus: .stopped)
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
        // session down — releasing these scopes — between attempts, and that
        // teardown resets the Recovery flag this re-sets below.
        instance.openRuntimeFileAccess()
        instance.bootedIntoRecovery = bootIntoRecovery
        let result = try await buildConfiguration(for: instance)
        instance.serialInputPipe = result.serialInputPipe
        instance.serialOutputPipe = result.serialOutputPipe
        instance.clipboardInputPipe = result.clipboardInputPipe
        instance.clipboardOutputPipe = result.clipboardOutputPipe
        instance.liveRemovableMedia = result.coldRemovableMedia
        let session = await instance.attachSession(from: result.configuration)
        instance.startSerialReading()
        instance.startClipboardService()
        await instance.startVsockServices()
        let startOptions = Self.recoveryStartOptions(
            bootIntoRecovery: bootIntoRecovery, guestOS: instance.configuration.guestOS)
        try await session.start(options: startOptions)
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
    /// macOS guest. `nonisolated` so the fresh options object stays in a
    /// disconnected region the session's `sending` parameter can take.
    nonisolated static func recoveryStartOptions(
        bootIntoRecovery: Bool, guestOS: VMGuestOS
    ) -> VZMacOSVirtualMachineStartOptions? {
        guard bootIntoRecovery, guestOS == .macOS else { return nil }
        let options = VZMacOSVirtualMachineStartOptions()
        options.startUpFromMacOSRecovery = true
        return options
    }

    // MARK: - Stop

    /// Requests a graceful ACPI shutdown of the virtual machine.
    func stop(_ instance: VMInstance) async throws {
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

        guard instance.status.canStop, let session = instance.session else {
            throw VirtualizationError.invalidStateTransition(from: instance.status, action: "stop")
        }

        try await session.requestStop()
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

        guard let session = instance.session else {
            throw VirtualizationError.noVirtualMachine
        }

        try await session.stop()
        instance.resetToStopped()
        Self.logger.notice("Force-stopped VM '\(instance.name, privacy: .public)'")
    }

    // MARK: - Pause / Resume

    func pause(_ instance: VMInstance) async throws {
        Self.logger.debug("pause: status=\(instance.status.displayName, privacy: .public)")
        guard instance.status.canPause, let session = instance.session else {
            throw VirtualizationError.invalidStateTransition(from: instance.status, action: "pause")
        }

        do {
            try await session.pause()
            instance.status = .paused
            // The grace clock only means something while the guest is executing
            // — a frozen guest cannot say Hello, so letting it run would blame
            // the agent for the pause.
            instance.cancelAgentPostStartWatchdog()
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
            "resume: status=\(instance.status.displayName, privacy: .public), hasVM=\(instance.hasLiveVirtualMachine, privacy: .public), hasSaveFile=\(instance.hasSaveFile, privacy: .public)"
        )
        guard instance.status.canResume else {
            throw VirtualizationError.invalidStateTransition(from: instance.status, action: "resume")
        }

        do {
            if let session = instance.session {
                try await session.resume()
                instance.status = .running
                // Idempotent re-activation reconciles an attachment the host
                // link may have invalidated during the pause.
                instance.networkAttachmentCoordinator?.activate()
                instance.removeSaveFile()
                // The guest is executing again, and this is the same session
                // that was paused — so `bootedIntoRecovery` still governs, and
                // a channel that died during the pause gets its grace clock
                // back. A no-op while the agent is connected.
                instance.startAgentPostStartWatchdog()
            } else if instance.hasSaveFile {
                // Deliberately arms nothing: a restore resumes whatever guest
                // state was frozen, which may be a Recovery session that never
                // runs the agent, and no host-side flag survives the save to
                // say which. The accept path arms once a control channel
                // actually shows up.
                try await restoreFromSaveFile(instance)
                instance.status = .running
                instance.networkAttachmentCoordinator?.activate()
            } else {
                throw VirtualizationError.noSaveFile
            }

            Self.logger.notice("Resumed VM '\(instance.name, privacy: .public)'")
        } catch {
            // A restore failure already logged itself with the full error chain.
            if !Self.isRestoreFailure(error) {
                Self.logger.error(
                    "Failed to resume VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
            }
            instance.tearDownSession()
            Self.applyLifecycleFailure(error, to: instance, transientRestingStatus: nil)
            throw error
        }
    }

    // MARK: - Save / Restore

    /// Saves the current VM state to disk (pause + snapshot).
    func save(_ instance: VMInstance) async throws {
        Self.logger.debug("save: status=\(instance.status.displayName, privacy: .public)")
        guard instance.status.canSave, let session = instance.session else {
            throw VirtualizationError.invalidStateTransition(from: instance.status, action: "save")
        }

        instance.status = .saving

        do {
            try await session.pauseIfRunning()
            try await session.saveMachineState(to: instance.saveFileURL)
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
        underlyingErrorChain(error as NSError).contains {
            $0.domain == VZError.errorDomain
                && VZError.Code(rawValue: $0.code) == .virtualMachineLimitExceeded
        }
    }

    /// `domain code` for each error *under* `error`, bounded by
    /// ``maxUnderlyingErrorDepth``; `"none"` when nothing is nested.
    static func underlyingChainDescription(_ error: NSError) -> String {
        let nested = underlyingErrorChain(error).dropFirst()
        guard !nested.isEmpty else { return "none" }
        return nested.map { "\($0.domain) \($0.code)" }.joined(separator: " → ")
    }

    /// `error` followed by up to ``maxUnderlyingErrorDepth`` of its
    /// `NSUnderlyingErrorKey` ancestors.
    private static func underlyingErrorChain(_ error: NSError) -> [NSError] {
        var chain: [NSError] = []
        var current: NSError? = error
        while let nsError = current, chain.count <= maxUnderlyingErrorDepth {
            chain.append(nsError)
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }

    /// `true` when `error` is a failed save-file restore — the one start/resume
    /// failure that rests at cold-paused instead of `.error` or `.stopped`.
    static func isRestoreFailure(_ error: Error) -> Bool {
        guard let virtualizationError = error as? VirtualizationError,
            case .restoreFailed = virtualizationError
        else { return false }
        return true
    }

    /// `error` with one `restoreFailed` wrapper peeled off, so the contention
    /// and transience classifiers can read the VZ failure underneath.
    static func unwrappedRestoreFailure(_ error: Error) -> Error {
        guard let virtualizationError = error as? VirtualizationError,
            case .restoreFailed(let underlying) = virtualizationError
        else { return error }
        return underlying
    }

    /// Records a failed start or resume on `instance`, after the caller's
    /// `tearDownSession()`. A failed save-file restore rests via
    /// ``applyRestoreFailure(to:)``; anything else classifies through
    /// ``applyStartFailure(_:to:transientRestingStatus:)`` when
    /// `transientRestingStatus` is given (a start), or rests at `.error`
    /// carrying the message (a resume).
    static func applyLifecycleFailure(
        _ error: Error, to instance: VMInstance, transientRestingStatus: VMStatus?
    ) {
        if isRestoreFailure(error) {
            applyRestoreFailure(to: instance)
        } else if let transientRestingStatus {
            applyStartFailure(error, to: instance, transientRestingStatus: transientRestingStatus)
        } else {
            instance.status = .error
            instance.errorMessage = error.localizedDescription
        }
    }

    /// Records a failed save-file restore on `instance`, after the caller's
    /// `tearDownSession()`: back at cold-paused with the save file untouched,
    /// so the user can retry the resume or explicitly discard the saved state.
    /// If the save file is gone — discarded while the attempt was in flight —
    /// rests at `.stopped` instead: `.paused` without a save file is a dead end.
    /// No stored message — the failure reaches the user as a thrown error.
    static func applyRestoreFailure(to instance: VMInstance) {
        instance.status = instance.hasSaveFile ? .paused : .stopped
        instance.errorMessage = nil
    }

    /// Records a failed start or install on `instance`: a transient failure
    /// rests at `transientRestingStatus` carrying no message, a permanent one
    /// lands in `.error` carrying the description the banner and tooltip show.
    ///
    /// `transientRestingStatus` is where the VM was before the attempt —
    /// `.stopped` for a plain start, `.initialBoot` for a pending install.
    static func applyStartFailure(
        _ error: Error, to instance: VMInstance, transientRestingStatus: VMStatus
    ) {
        let isTransient = isTransientStartError(error)
        instance.status = isTransient ? transientRestingStatus : .error
        instance.errorMessage = isTransient ? nil : error.localizedDescription
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

    /// Builds a `VZVirtualMachine`, restores from a save file, and resumes,
    /// retrying with bounded backoff when the attempt fails on VZ file-lock
    /// contention (see ``isFileLockContention(_:)``) — the restore-path
    /// counterpart of ``coldBootRetryingLockContention(_:bootIntoRecovery:)``.
    ///
    /// A restore or resume failure surfaces as
    /// ``VirtualizationError/restoreFailed(underlying:)`` with the save file
    /// left in place — a cold boot over a suspended session destroys it, so
    /// discarding the saved state stays an explicit user action
    /// (`stop(_:)` on a cold-paused VM).
    private func restoreFromSaveFile(_ instance: VMInstance) async throws {
        var attempt = 0
        while true {
            do {
                try await restoreFromSaveFileAttempt(instance)
                return
            } catch let attemptError {
                guard Self.isFileLockContention(Self.unwrappedRestoreFailure(attemptError)),
                    let delay = Self.fileLockRetryDelay(forAttempt: attempt)
                else { throw attemptError }
                attempt += 1
                Self.logger.warning(
                    "Restore of '\(instance.name, privacy: .public)' hit file-lock contention; retry \(attempt, privacy: .public) in \(String(describing: delay), privacy: .public)"
                )
                instance.tearDownSession()
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    // Cancelled mid-backoff: surface the original lock failure
                    // rather than leak a `CancellationError` into the status/alert
                    // classification paths, which aren't shaped for it.
                    throw attemptError
                }
            }
        }
    }

    /// One restore attempt: build, attach, restore, resume. A configuration
    /// build failure propagates as-is (the caller's attachment explainers
    /// match on it); a restore or resume failure is wrapped in `restoreFailed`.
    private func restoreFromSaveFileAttempt(_ instance: VMInstance) async throws {
        instance.openRuntimeFileAccess()
        let result = try await buildConfiguration(for: instance)

        instance.serialInputPipe = result.serialInputPipe
        instance.serialOutputPipe = result.serialOutputPipe
        instance.clipboardInputPipe = result.clipboardInputPipe
        instance.clipboardOutputPipe = result.clipboardOutputPipe
        instance.liveRemovableMedia = result.coldRemovableMedia
        let session = await instance.attachSession(from: result.configuration)
        instance.startSerialReading()
        instance.startClipboardService()
        await instance.startVsockServices()

        Self.logger.debug("restoreFromSaveFile: attempting restore from save file")
        do {
            instance.status = .restoring
            try await session.restoreMachineState(from: instance.saveFileURL)
            try await session.resume()
            instance.removeSaveFile()
        } catch {
            let nsError = error as NSError
            Self.logger.error(
                "Restore failed for VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public) [\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public); underlying: \(Self.underlyingChainDescription(nsError), privacy: .public)]"
            )
            throw VirtualizationError.restoreFailed(underlying: error)
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
    case restoreFailed(underlying: any Error)

    var errorDescription: String? {
        switch self {
        case .invalidStateTransition(let status, let action):
            "Cannot \(action) VM in \(status.displayName) state."
        case .noVirtualMachine:
            "No virtual machine instance is available."
        case .noSaveFile:
            "No saved state file found."
        case .restoreFailed(let underlying):
            "Could not restore the saved state: \(underlying.localizedDescription)\n\n"
                + "The saved state was kept — choose Resume to try again, "
                + "or Discard Saved State to remove it and start fresh."
        }
    }
}

/// Bridges `restoreFailed`'s underlying error into `NSUnderlyingErrorKey` so
/// the chain-walking classifiers (`isVirtualMachineLimitExceeded`,
/// `underlyingChainDescription`) see through the wrapper.
extension VirtualizationError: CustomNSError {
    var errorUserInfo: [String: Any] {
        guard case .restoreFailed(let underlying) = self else { return [:] }
        return [NSUnderlyingErrorKey: underlying as NSError]
    }
}
