import Foundation
import KernovaKit
import Virtualization
import os

/// Manages macOS guest installation using `VZMacOSInstaller`.
@MainActor
final class MacOSInstallService {
    private static let logger = Logger(subsystem: "app.kernova", category: "MacOSInstallService")

    private let configBuilder = ConfigurationBuilder()
    private let storageService = VMStorageService()
    private var progressObservation: NSKeyValueObservation?

    // MARK: - Installation

    /// Installs macOS from a restore image into the given VM instance.
    ///
    /// `progressHandler` receives installation progress in 0.0–1.0.
    ///
    /// - Returns: The image's own version and build, read off the loaded
    ///   `VZMacOSRestoreImage` rather than the install intent that named it.
    /// - Throws: ``MacOSInstallError`` if the restore image is missing or
    ///   incompatible with this host, or any error rethrown from `VZMacOSInstaller`.
    func install(
        into instance: VMInstance,
        restoreImageURL: URL,
        progressHandler: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws -> InstalledImage {
        instance.status = .installing

        Self.logger.info("Starting macOS installation for '\(instance.name, privacy: .public)'")

        // Both VZ hand-offs below take the resolved URL — see `resolveRestoreImage`.
        let imageURL = try Self.resolveRestoreImage(at: restoreImageURL)
        let restoreImage = try await loadRestoreImage(from: imageURL)

        guard let supportedConfig = restoreImage.mostFeaturefulSupportedConfiguration else {
            throw MacOSInstallError.unsupportedRestoreImage
        }

        guard supportedConfig.hardwareModel.isSupported else {
            throw MacOSInstallError.unsupportedHardwareModel
        }

        try setupPlatformFiles(
            for: instance,
            hardwareModel: supportedConfig.hardwareModel
        )

        instance.configuration.hardwareModelData = supportedConfig.hardwareModel.dataRepresentation

        let machineIDURL = instance.machineIdentifierURL
        let machineIDData = try Data(contentsOf: machineIDURL)
        instance.configuration.machineIdentifierData = machineIDData

        try storageService.saveConfiguration(instance.configuration, to: instance.bundleURL)

        // The install-time build needs the same security scopes as the boot paths —
        // a pre-install VM can already carry bookmarked external attachments from
        // settings. Session teardown releases them.
        instance.openRuntimeFileAccess()
        let result = try configBuilder.build(
            from: instance.configuration,
            bundleURL: instance.bundleURL
        )

        instance.serialInputPipe = result.serialInputPipe
        instance.serialOutputPipe = result.serialOutputPipe
        instance.clipboardInputPipe = result.clipboardInputPipe
        instance.clipboardOutputPipe = result.clipboardOutputPipe
        // RATIONALE: `attachVirtualMachine` runs *before* the cancellation check
        // below on purpose. A cancel in this window unwinds with
        // `instance.virtualMachine` set, which
        // `VMLibraryViewModel.runGuestSetup`'s `catch is CancellationError`
        // tears down. Checking first would leave the configured pipes dangling on
        // `instance` with no matching VM.
        let vm = instance.attachVirtualMachine(from: result.configuration)
        instance.startSerialReading()
        instance.startClipboardService()

        try Task.checkCancellation()

        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: imageURL)

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

        // `VZMacOSInstaller.install` resolves its completion handler before VZ has
        // finished propagating the post-install guest shutdown through `vm.state`.
        // Without this wait the caller's auto-boot races the auxiliary-storage file
        // lock ("Failed to lock auxiliary storage"), and `guestDidStop` hasn't yet
        // cleared `instance.virtualMachine`.
        await Self.waitForVMStopped(vm)

        // `waitForVMStopped` observes cancellation but never throws, so the signal
        // has to be re-raised here: otherwise a cancel landing during the wait lets
        // the install return success and `runGuestSetup` auto-boots it.
        try Task.checkCancellation()

        // If the delegate never fired (timed out, or deallocated before
        // `guestDidStop` ran), tear down explicitly so a later boot doesn't
        // observe a stale attached VM.
        if instance.virtualMachine != nil {
            instance.resetToStopped()
        }

        instance.setupState?.progress = .fraction(1.0)

        Self.logger.info("macOS installation completed for '\(instance.name, privacy: .public)'")

        return .macOSRestoreImage(
            version: KernovaOSVersion.displayString(restoreImage.operatingSystemVersion),
            build: restoreImage.buildVersion)
    }

    /// Waits for `vm.state` to reach `.stopped`, the timeout to elapse, or the
    /// surrounding `Task` to be cancelled — whichever comes first.
    ///
    /// Never throws; outer cancellation only suppresses the timeout warning.
    /// Bridges `vm.state`'s KVO through `NSObject.observe(_:options:)` rather than
    /// Combine's `publisher(for:).values`, whose `AsyncPublisher` isn't `Sendable`
    /// when its subject isn't — and the sequence has to cross into a task-group
    /// child.
    private static func waitForVMStopped(
        _ vm: VZVirtualMachine,
        timeout: Duration = .seconds(30)
    ) async {
        // Quick path for the common case where VZ propagated synchronously.
        if vm.state == .stopped { return }

        let (stream, continuation) = AsyncStream<Void>.makeStream()

        // The `defer { invalidate() }` below keeps the observation alive for the
        // lifetime of this function; losing the reference silently stops it.
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
                // `for await` over `AsyncStream` returns when the consumer's task
                // is cancelled, so `group.cancelAll()` below unblocks this child
                // without further plumbing.
                for await _ in stream { return }
            }
            group.addTask {
                // `try?`: when the group cancels this child the sleep throws, and
                // exiting silently is what lets the group complete.
                try? await Task.sleep(for: timeout)
            }
            _ = await group.next()
            group.cancelAll()
        }

        // A timeout is an anomaly; a user cancel is not. Log only the former.
        if vm.state != .stopped && !Task.isCancelled {
            logger.warning(
                "VM did not reach .stopped within timeout (state: \(String(describing: vm.state), privacy: .public))"
            )
        }
    }

    // MARK: - Platform Setup

    /// Creates the auxiliary storage, hardware model, and machine identifier files.
    ///
    /// Idempotent across install retries: hardware model and machine identifier are
    /// written only when absent, so the guest sees a stable machine identity however
    /// many attempts it took. Auxiliary storage is always re-created — it carries
    /// firmware/NVRAM state that must match a fresh install run.
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

        // Without `.allowOverwrite`, a second Start after an install that got past
        // setup but didn't finish throws "File exists" before the installer runs.
        _ = try VZMacAuxiliaryStorage(
            creatingStorageAt: instance.auxiliaryStorageURL,
            hardwareModel: hardwareModel,
            options: [.allowOverwrite]
        )

        Self.logger.info("Created platform files for '\(instance.name, privacy: .public)'")
    }

    // MARK: - Helpers

    /// Resolves the restore image through symlinks, mapping `PathValidation.Failure`
    /// to ``MacOSInstallError``.
    ///
    /// RATIONALE: VZ rejects a restore image whose path traverses a symlink in
    /// *any* component and never resolves it itself — `VZMacOSRestoreImage.load`
    /// fails `VZErrorInvalidRestoreImage` on a file `FileManager` calls readable,
    /// and `VZMacOSInstaller.init` is documented to *raise an exception*. Under the
    /// sandbox `.downloadsDirectory` is itself a symlink.
    static func resolveRestoreImage(at url: URL) throws -> URL {
        let path = url.path(percentEncoded: false)
        do {
            let resolved = try PathValidation.resolveFile(at: path)
            resolved.logResolution(logger: logger, context: "Restore image")
            return resolved.url
        } catch {
            // Report the symlink-resolved path: `errorDescription` reaches the user,
            // and the raw path is the container's `Downloads` spelling, not the
            // `~/Downloads/…` they know.
            //
            // RATIONALE: resolve the *parent* and re-attach the file name.
            // `resolvingSymlinksInPath()` is existence-dependent — it returns the
            // path untouched when the last component is missing, which is exactly
            // the `.notFound` case here.
            let reportedPath =
                url.deletingLastPathComponent()
                .resolvingSymlinksInPath()
                .appendingPathComponent(url.lastPathComponent)
                .path(percentEncoded: false)
            switch error {
            case .notFound:
                logger.error("Restore image not found at '\(reportedPath, privacy: .private)'")
                throw MacOSInstallError.restoreImageNotFound(path: reportedPath)
            case .unexpectedType:
                logger.error("Restore image path is a directory: '\(reportedPath, privacy: .private)'")
                throw MacOSInstallError.restoreImageNotAFile(path: reportedPath)
            case .notReadable, .notWritable:
                // `resolveFile` only throws these when `requireWritable` is set,
                // which we don't — VZ opening the file is the authoritative
                // readability test.
                logger.fault("Unexpected \(String(describing: error), privacy: .public) for restore image")
                assertionFailure("Unexpected PathValidation failure for restore image: \(error)")
                throw MacOSInstallError.restoreImageNotFound(path: reportedPath)
            }
        }
    }

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
    case restoreImageNotFound(path: String)
    case restoreImageNotAFile(path: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedRestoreImage:
            "The restore image does not contain a supported macOS configuration."
        case .unsupportedHardwareModel:
            "The hardware model in the restore image is not supported on this machine."
        case .restoreImageNotFound(let path):
            "The restore image could not be found at \(path)."
        case .restoreImageNotAFile(let path):
            "The restore image at \(path) is a folder, not a file."
        }
    }
}
