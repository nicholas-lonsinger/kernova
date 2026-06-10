import Foundation
import Virtualization
import os

/// Manages macOS guest installation using `VZMacOSInstaller`.
///
/// Handles the full installation pipeline:
/// 1. Load restore image and extract hardware model
/// 2. Create platform configuration (auxiliary storage, hardware model, machine identifier)
/// 3. Build VZ configuration and create the virtual machine
/// 4. Run the installer with progress tracking via KVO
@MainActor
final class MacOSInstallService {
    private static let logger = Logger(subsystem: "app.kernova", category: "MacOSInstallService")

    private let configBuilder = ConfigurationBuilder()
    private let storageService = VMStorageService()
    private var progressObservation: NSKeyValueObservation?

    // MARK: - Installation

    /// Installs macOS from a restore image into the given VM instance.
    ///
    /// - Parameters:
    ///   - instance: The VM instance to install into.
    ///   - restoreImageURL: The local URL of the IPSW file.
    ///   - progressHandler: Called with installation progress (0.0–1.0).
    /// - Throws: ``MacOSInstallError`` if the restore image is incompatible with this host,
    ///   or any error rethrown from the underlying `VZMacOSInstaller`.
    func install(
        into instance: VMInstance,
        restoreImageURL: URL,
        progressHandler: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws {
        instance.status = .installing

        Self.logger.info("Starting macOS installation for '\(instance.name, privacy: .public)'")

        // 1. Load restore image
        let restoreImage = try await loadRestoreImage(from: restoreImageURL)

        guard let supportedConfig = restoreImage.mostFeaturefulSupportedConfiguration else {
            throw MacOSInstallError.unsupportedRestoreImage
        }

        guard supportedConfig.hardwareModel.isSupported else {
            throw MacOSInstallError.unsupportedHardwareModel
        }

        // 2. Set up platform configuration
        try setupPlatformFiles(
            for: instance,
            hardwareModel: supportedConfig.hardwareModel
        )

        // 3. Update the VM configuration with hardware model data
        instance.configuration.hardwareModelData = supportedConfig.hardwareModel.dataRepresentation

        let machineIDURL = instance.machineIdentifierURL
        let machineIDData = try Data(contentsOf: machineIDURL)
        instance.configuration.machineIdentifierData = machineIDData

        try storageService.saveConfiguration(instance.configuration, to: instance.bundleURL)

        // 4. Build VZ configuration and create VM
        let result = try configBuilder.build(
            from: instance.configuration,
            bundleURL: instance.bundleURL
        )

        instance.serialInputPipe = result.serialInputPipe
        instance.serialOutputPipe = result.serialOutputPipe
        instance.clipboardInputPipe = result.clipboardInputPipe
        instance.clipboardOutputPipe = result.clipboardOutputPipe
        // RATIONALE: `attachVirtualMachine` runs *before* the cancellation
        // check below on purpose. If a cancel lands in this window, the
        // throw at step 5 unwinds with `instance.virtualMachine` already
        // set; `VMLibraryViewModel.installAndAutoBoot`'s
        // `catch is CancellationError` then calls `tearDownSession()` to
        // release the VM. Moving the check above `attachVirtualMachine`
        // would skip wiring the delegate and leave the configured pipes
        // dangling on `instance` without a matching VM — harder to clean
        // up than the current ordering.
        let vm = instance.attachVirtualMachine(from: result.configuration)
        instance.startSerialReading()
        instance.startClipboardService()

        // 5. Check for cancellation before starting the installer
        try Task.checkCancellation()

        // 6. Run installer with progress tracking
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: restoreImageURL)

        // Observe progress via KVO
        progressObservation = installer.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                progressHandler(fraction)
            }
        }

        defer {
            progressObservation?.invalidate()
            progressObservation = nil
        }

        // Capture progress for the @Sendable onCancel closure (VZMacOSInstaller is not Sendable)
        let installerProgress = installer.progress

        Self.logger.info("Running macOS installer...")
        try await withTaskCancellationHandler {
            try await installer.install()
        } onCancel: {
            installerProgress.cancel()
        }

        // `VZMacOSInstaller.install` resolves its completion handler before
        // VZ has finished propagating the post-install guest shutdown
        // through `vm.state`. Without waiting, the caller's auto-boot would
        // run while the VM is still transitioning — historically that
        // raced the auxiliary-storage file lock (cold-boot rebuilding a
        // fresh `VZMacAuxiliaryStorage(contentsOf:)` while the install-
        // side instance still held the lock) and produced the
        // "Failed to lock auxiliary storage" error from the original repro.
        //
        // Waiting here also gives our `VZVirtualMachineDelegate.guestDidStop`
        // a chance to fire as the VM reaches `.stopped`, which clears
        // `instance.virtualMachine` and resets our status — so by the
        // time the caller's cold-boot runs, refs and locks are released
        // and the new start path has a clean slate.
        await Self.waitForVMStopped(vm)

        // `waitForVMStopped` honors `Task.isCancelled` internally (it
        // suppresses the timeout warning when cancelled) but intentionally
        // doesn't throw — so the cancel signal has to be re-raised here
        // at the function's success/failure boundary. Without this, a
        // cancel that lands during the wait would let the install return
        // success and the caller (`installAndAutoBoot`) would auto-boot
        // a cancelled install. The throw routes through the coordinator's
        // `catch is CancellationError` → `installAndAutoBoot`'s same arm
        // → `tearDownSession`, status `.initialBoot`, no auto-boot.
        try Task.checkCancellation()

        // Belt-and-braces: if the delegate didn't fire (timed out, or
        // the adapter was deallocated before `guestDidStop` ran), tear
        // down explicitly so a subsequent boot doesn't observe a stale
        // attached VM.
        if instance.virtualMachine != nil {
            instance.resetToStopped()
        }

        instance.installState?.currentPhase = .installing(progress: 1.0)

        Self.logger.info("macOS installation completed for '\(instance.name, privacy: .public)'")
    }

    /// Waits for `vm.state` to reach `.stopped`, the timeout to elapse, or
    /// the surrounding `Task` to be cancelled — whichever comes first.
    ///
    /// Bridges `VZVirtualMachine.state`'s built-in KVO compliance into an
    /// `AsyncStream<Void>` (the observer yields exactly once when state
    /// becomes `.stopped`), raced against `Task.sleep` inside a
    /// `TaskGroup`. Cancellation of the surrounding task propagates
    /// structurally to both children: the observer task's `next()` returns
    /// `nil` when the consumer's task is cancelled, and `Task.sleep` throws
    /// — caught silently with `try?` so the group can complete. The
    /// function then detects outer cancellation via `Task.isCancelled` and
    /// skips the timeout warning (a user cancel is intentional behavior,
    /// not an anomaly worth flagging).
    ///
    /// We use `NSObject.observe(_:options:)` directly instead of Combine's
    /// `publisher(for:).values` because the latter's `AsyncPublisher` isn't
    /// `Sendable` when its underlying `Subject` (here `VZVirtualMachine`)
    /// isn't, and we need to pass the sequence into a task group child.
    private static func waitForVMStopped(
        _ vm: VZVirtualMachine,
        timeout: Duration = .seconds(30)
    ) async {
        // Quick path: already stopped (avoids spinning up the bridge for
        // the common case where VZ propagated synchronously).
        if vm.state == .stopped { return }

        let (stream, continuation) = AsyncStream<Void>.makeStream()

        // The observer's changeHandler fires on whichever thread mutated
        // `vm.state` — for `@MainActor`-bound VZ that's the main actor, so
        // the `yield`/`finish` here are serialised with our own MainActor
        // reads of `vm.state`. The `defer { invalidate() }` keeps the
        // observer alive for the lifetime of this function — losing the
        // reference earlier would silently stop observation.
        let observation = vm.observe(\.state, options: [.new]) { observed, _ in
            if observed.state == .stopped {
                continuation.yield(())
                continuation.finish()
            }
        }
        defer { observation.invalidate() }

        // Cover the race: state may have transitioned to `.stopped` between
        // the initial guard and observer registration above.
        if vm.state == .stopped {
            continuation.finish()
            return
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // First yield (or stream finish) wins. `for await` over
                // `AsyncStream` returns when the consumer's task is
                // cancelled, so `group.cancelAll()` below unblocks this
                // child without further plumbing.
                for await _ in stream { return }
            }
            group.addTask {
                // `try?` here is the right shape — when the group cancels
                // this child (either because the observer finished first or
                // because the surrounding task was cancelled), the sleep
                // throws `CancellationError` and we want to silently exit
                // so the group can complete. Outer cancellation is detected
                // via `Task.isCancelled` after the group returns, not by
                // re-throwing here (which would force a throwing group for
                // no gain).
                try? await Task.sleep(for: timeout)
            }
            _ = await group.next()
            group.cancelAll()
        }

        // Distinguish timeout (genuine anomaly) from user cancel
        // (intentional) when emitting diagnostics — log only the former.
        if vm.state != .stopped && !Task.isCancelled {
            logger.warning(
                "VM did not reach .stopped within timeout (state: \(String(describing: vm.state), privacy: .public))"
            )
        }
    }

    // MARK: - Platform Setup

    /// Creates the auxiliary storage, hardware model, and machine identifier files.
    ///
    /// Idempotent across install retries: hardware model and machine identifier
    /// files are written only when absent so the VM keeps a stable on-disk identity
    /// across attempts (the guest install sees the same machine regardless of how
    /// many tries it took).
    ///
    /// Auxiliary storage is always re-created — it carries firmware/NVRAM state
    /// that must match a fresh install run.
    private func setupPlatformFiles(
        for instance: VMInstance,
        hardwareModel: VZMacHardwareModel
    ) throws {
        let fm = FileManager.default

        if !fm.fileExists(atPath: instance.hardwareModelURL.path(percentEncoded: false)) {
            try hardwareModel.dataRepresentation.write(to: instance.hardwareModelURL)
        }

        if !fm.fileExists(atPath: instance.machineIdentifierURL.path(percentEncoded: false)) {
            let machineIdentifier = VZMacMachineIdentifier()
            try machineIdentifier.dataRepresentation.write(to: instance.machineIdentifierURL)
        }

        // `.allowOverwrite` lets us re-create the file when a prior install attempt
        // got past setup but didn't finish — without it, the second Start throws
        // "File exists" before the installer even runs.
        _ = try VZMacAuxiliaryStorage(
            creatingStorageAt: instance.auxiliaryStorageURL,
            hardwareModel: hardwareModel,
            options: [.allowOverwrite]
        )

        Self.logger.info("Created platform files for '\(instance.name, privacy: .public)'")
    }

    // MARK: - Helpers

    private func loadRestoreImage(from url: URL) async throws -> VZMacOSRestoreImage {
        try await VZMacOSRestoreImage.image(from: url)
    }
}

// MARK: - MacOSInstallProviding

extension MacOSInstallService: MacOSInstallProviding {}

// MARK: - Errors

enum MacOSInstallError: LocalizedError {
    case unsupportedRestoreImage
    case unsupportedHardwareModel

    var errorDescription: String? {
        switch self {
        case .unsupportedRestoreImage:
            "The restore image does not contain a supported macOS configuration."
        case .unsupportedHardwareModel:
            "The hardware model in the restore image is not supported on this machine."
        }
    }
}
