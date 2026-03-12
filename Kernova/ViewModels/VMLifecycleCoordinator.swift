import Foundation
import os

/// Coordinates VM lifecycle operations and macOS installation.
///
/// Groups all state-changing VM operations into a single type, keeping
/// `VMLibraryViewModel` focused on list management and UI state.
/// All methods re-throw errors — the caller is responsible for presentation.
@MainActor
final class VMLifecycleCoordinator {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "VMLifecycleCoordinator")

    let virtualizationService: any VirtualizationProviding
    let installService: any MacOSInstallProviding
    let ipswService: any IPSWProviding

    init(
        virtualizationService: any VirtualizationProviding,
        installService: any MacOSInstallProviding,
        ipswService: any IPSWProviding
    ) {
        self.virtualizationService = virtualizationService
        self.installService = installService
        self.ipswService = ipswService
    }

    // MARK: - Lifecycle

    func start(_ instance: VMInstance) async throws {
        try await virtualizationService.start(instance)
    }

    func stop(_ instance: VMInstance) throws {
        try virtualizationService.stop(instance)
    }

    func forceStop(_ instance: VMInstance) async throws {
        try await virtualizationService.forceStop(instance)
    }

    func pause(_ instance: VMInstance) async throws {
        try await virtualizationService.pause(instance)
    }

    func resume(_ instance: VMInstance) async throws {
        try await virtualizationService.resume(instance)
    }

    func save(_ instance: VMInstance) async throws {
        try await virtualizationService.save(instance)
    }

    // MARK: - macOS Installation

    #if arch(arm64)
    func installMacOS(
        on instance: VMInstance,
        wizard: VMCreationViewModel,
        storageService: any VMStorageProviding
    ) async throws {
        Self.logger.debug("installMacOS: entering for '\(instance.name)', source=\(String(describing: wizard.ipswSource))")
        do {
            let ipswURL: URL

            switch wizard.ipswSource {
            case .downloadLatest:
                guard let downloadPath = wizard.ipswDownloadPath else {
                    throw IPSWError.noDownloadURL
                }
                let downloadDestination = URL(fileURLWithPath: downloadPath)

                // Set up two-step install state before changing status
                instance.installState = MacOSInstallState(
                    hasDownloadStep: true,
                    currentPhase: .downloading(progress: 0, bytesWritten: 0, totalBytes: 0)
                )
                instance.status = .installing

                // Download the latest IPSW to user-chosen location
                let remoteURL = try await ipswService.fetchLatestRestoreImageURL()
                try await ipswService.downloadRestoreImage(
                    from: remoteURL,
                    to: downloadDestination
                ) { progress, bytesWritten, totalBytes in
                    instance.installState?.currentPhase = .downloading(
                        progress: progress,
                        bytesWritten: bytesWritten,
                        totalBytes: totalBytes
                    )
                }

                // Mark download complete, transition to install phase
                instance.installState?.downloadCompleted = true
                instance.installState?.currentPhase = .installing(progress: 0)
                ipswURL = downloadDestination

            case .localFile:
                guard let path = wizard.ipswPath else {
                    throw IPSWError.noDownloadURL
                }
                ipswURL = URL(fileURLWithPath: path)

                // Local file: single-step install (no download)
                instance.installState = MacOSInstallState(
                    hasDownloadStep: false,
                    currentPhase: .installing(progress: 0)
                )
                instance.status = .installing
            }

            // Run macOS installation
            try await installService.install(
                into: instance,
                restoreImageURL: ipswURL
            ) { @MainActor progress in
                instance.installState?.currentPhase = .installing(progress: progress)
            }
        } catch is CancellationError {
            Self.logger.info("macOS installation cancelled for '\(instance.name)'")
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            Self.logger.info("IPSW download cancelled for '\(instance.name)'")
        } catch {
            instance.status = .error
            instance.errorMessage = error.localizedDescription
            throw error
        }

        instance.installTask = nil
    }
    #endif
}
