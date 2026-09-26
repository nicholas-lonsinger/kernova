import Foundation
import KernovaKit
import KernovaLogging
import Virtualization

/// Manages macOS guest installation using `VZMacOSInstaller`.
@MainActor
final class MacOSInstallService {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "MacOSInstallService")

    private let configBuilder: ConfigurationBuilder

    init(vmnetNetworks: any VmnetNetworkProviding, entitlements: EntitlementService) {
        configBuilder = ConfigurationBuilder(vmnetNetworks: vmnetNetworks, entitlements: entitlements)
    }

    // MARK: - Installation

    /// Installs macOS from a restore image into the given VM instance, under
    /// the guest-setup bring-up that holds it.
    ///
    /// `progressHandler` receives installation progress in 0.0–1.0.
    ///
    /// - Returns: The image's own version and build, read off the loaded
    ///   `VZMacOSRestoreImage` rather than the install intent that named it.
    /// - Throws: ``MacOSInstallError`` if the restore image is missing or
    ///   incompatible with this host, or any error rethrown from `VZMacOSInstaller`.
    func install(
        into instance: VMInstance,
        _ context: borrowing VMBringUpContext,
        restoreImageURL: URL,
        progressHandler: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws -> InstalledImage {
        #log(Self.logger, .info, "Starting macOS installation for '\(instance.name, privacy: .public)'")

        // Both VZ hand-offs below take the resolved URL — see `resolveRestoreImage`.
        let imageURL = try Self.resolveRestoreImage(at: restoreImageURL)
        let restoreImage = try await loadRestoreImage(from: imageURL)

        guard let supportedConfig = restoreImage.mostFeaturefulSupportedConfiguration else {
            throw MacOSInstallError.unsupportedRestoreImage
        }

        guard supportedConfig.hardwareModel.isSupported else {
            throw MacOSInstallError.unsupportedHardwareModel
        }

        let hardwareModelData = supportedConfig.hardwareModel.dataRepresentation
        let machineIDData = try await context.operation.bundle.createMacPlatformFiles(
            hardwareModel: hardwareModelData)
        // The install stops unless the identity lands: the build below prefers
        // the configuration's hardware model over the bundle's file, which
        // `createMacPlatformFiles` writes only when absent, so a model an
        // earlier attempt recorded would stand in for this image's.
        try instance.performConfigurationMutation {
            $0.hardwareModelData = hardwareModelData
            $0.machineIdentifierData = machineIDData
        }.get()

        instance.beginSessionContext(context)
        let result = try configBuilder.build(
            from: instance.effectiveConfiguration,
            bundleURL: context.operation.bundle.url
        )

        instance.adoptBuildResult(context, result)
        guard let session = await instance.attachSession(context, from: result) else {
            throw VirtualizationError.noVirtualMachine
        }
        // Short of `bringUpSession`: an installer boot runs no vsock
        // listeners, since no guest agent can be there to meet them.
        instance.startSerialReading()
        instance.startClipboardService()

        try Task.checkCancellation()

        #log(Self.logger, .info, "Running macOS installer...")
        try await session.installMacOS(from: imageURL) { fraction in
            Task { @MainActor in
                progressHandler(fraction)
            }
        }

        // `VZMacOSInstaller.install`'s completion is documented only as called
        // after the install succeeds or fails — not that the installer's VM
        // has stopped. `VZVirtualMachine.stop`'s completion is documented as
        // called once the VM has stopped or on error, so the session ends on
        // that rather than on a delegate event.
        #log(Self.logger, .notice, "Stopping the installer's VM for '\(instance.name, privacy: .public)'")
        do {
            let outcome =
                try await session.stopIfStoppable() ? "stopped" : "was not stoppable; treated as stopped"
            #log(
                Self.logger, .notice,
                "Installer's VM for '\(instance.name, privacy: .public)' \(outcome, privacy: .public)")
        } catch {
            #log(
                Self.logger, .error,
                "Stopping the installer's VM for '\(instance.name, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        context.operation.endSession()

        // A cancel landing after the stop has to be raised here, or the install
        // returns success and the setup chains a boot.
        try Task.checkCancellation()

        instance.setupState?.progress = .fraction(1.0)

        #log(Self.logger, .info, "macOS installation completed for '\(instance.name, privacy: .public)'")

        return .macOSRestoreImage(
            version: KernovaOSVersion.displayString(restoreImage.operatingSystemVersion),
            build: restoreImage.buildVersion)
    }

    // MARK: - Helpers

    /// Resolves the restore image through symlinks, mapping `PathValidation.Failure`
    /// to ``MacOSInstallError``.
    ///
    /// VZ rejects a restore image whose path traverses a symlink in *any*
    /// component and never resolves it itself — `VZMacOSRestoreImage.load` fails
    /// `VZErrorInvalidRestoreImage` on a file `FileManager` calls readable, and
    /// `VZMacOSInstaller.init` is documented to *raise an exception*. Under the
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
            // `~/Downloads/…` they know. `resolvingSymlinksInPath()` returns a path
            // untouched when its last component is missing — the `.notFound` case
            // — so the parent is resolved and the file name re-attached.
            let reportedPath =
                url.deletingLastPathComponent()
                .resolvingSymlinksInPath()
                .appendingPathComponent(url.lastPathComponent)
                .path(percentEncoded: false)
            switch error {
            case .notFound:
                #log(logger, .error, "Restore image not found at '\(reportedPath, privacy: .private)'")
                throw MacOSInstallError.restoreImageNotFound(path: reportedPath)
            case .unexpectedType:
                #log(logger, .error, "Restore image path is a directory: '\(reportedPath, privacy: .private)'")
                throw MacOSInstallError.restoreImageNotAFile(path: reportedPath)
            case .notReadable, .notWritable:
                // `resolveFile` never throws `.notReadable`, and throws
                // `.notWritable` only under `requireWritable`, which this call
                // doesn't set — VZ opening the file is the readability test.
                #log(logger, .fault, "Unexpected \(String(describing: error), privacy: .public) for restore image")
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
