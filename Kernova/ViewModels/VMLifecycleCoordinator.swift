import Foundation
import os

/// Coordinates VM lifecycle operations and macOS installation.
///
/// Groups all state-changing VM operations into a single type, keeping
/// `VMLibraryViewModel` focused on list management and UI state.
/// All methods re-throw errors — the caller is responsible for presentation.
///
/// **Operation serialization:** Each VM can have at most one in-flight lifecycle
/// operation at a time. Concurrent requests for the same VM are rejected with
/// ``LifecycleError/operationInProgress``. A token-based `[UUID: UUID]` dictionary
/// maps each VM to its current operation token. Since the coordinator is `@MainActor`,
/// no locks are required.
///
/// **Interruption-aware:** `stop` and `forceStop` bypass serialization entirely —
/// they clear the active-operation token *before* calling the underlying service.
/// This invalidates any in-flight operation's token so its `defer` cleanup won't
/// clobber a subsequent operation's entry.
@MainActor
final class VMLifecycleCoordinator {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "VMLifecycleCoordinator")

    let virtualizationService: any VirtualizationProviding
    let installService: any MacOSInstallProviding
    let ipswService: any IPSWProviding

    /// Maps VM ID → operation token for VMs that currently have a lifecycle operation in flight.
    /// The token allows `defer` blocks to avoid clobbering entries inserted by a later operation.
    private var activeOperations: [UUID: UUID] = [:]

    init(
        virtualizationService: any VirtualizationProviding,
        installService: any MacOSInstallProviding,
        ipswService: any IPSWProviding
    ) {
        self.virtualizationService = virtualizationService
        self.installService = installService
        self.ipswService = ipswService
    }

    // MARK: - Errors

    enum LifecycleError: LocalizedError {
        case operationInProgress(vmName: String)

        var errorDescription: String? {
            switch self {
            case .operationInProgress(let vmName):
                "An operation is already in progress for '\(vmName)'. Please wait for it to complete."
            }
        }
    }

    // MARK: - Operation Serialization

    /// Returns `true` if the given VM currently has a lifecycle operation in progress.
    func hasActiveOperation(for instanceID: UUID) -> Bool {
        activeOperations[instanceID] != nil
    }

    /// Removes any active-operation tracking for the given VM.
    /// Call when a VM is deleted to avoid stale entries in the dictionary.
    func clearActiveOperation(for instanceID: UUID) {
        activeOperations.removeValue(forKey: instanceID)
    }

    /// Executes `body` only if no other operation is already in flight for this VM.
    ///
    /// Generates a unique token per invocation. The `defer` block only removes the
    /// entry if its token still matches, preventing a stale removal from clobbering
    /// a token written by `stop`/`forceStop` or a subsequent operation.
    private func serialized<T>(
        _ instance: VMInstance,
        action: String,
        body: () async throws -> T
    ) async throws -> T {
        guard activeOperations[instance.id] == nil else {
            Self.logger.warning("Rejected \(action, privacy: .public) for '\(instance.name, privacy: .public)': operation already in progress")
            throw LifecycleError.operationInProgress(vmName: instance.name)
        }

        let token = UUID()
        activeOperations[instance.id] = token
        defer {
            if activeOperations[instance.id] == token {
                activeOperations.removeValue(forKey: instance.id)
            }
        }

        Self.logger.debug("Acquired operation lock for '\(instance.name, privacy: .public)' (action: \(action, privacy: .public))")
        return try await body()
    }

    // MARK: - Lifecycle

    func start(_ instance: VMInstance) async throws {
        try await serialized(instance, action: "start") {
            try await virtualizationService.start(instance)
        }
    }

    /// Requests a graceful stop. Bypasses serialization so users can always
    /// interrupt an in-progress operation (e.g. a hung start). Clears the
    /// active-operation token *before* calling the service, invalidating any
    /// in-flight operation's defer guard.
    func stop(_ instance: VMInstance) throws {
        activeOperations.removeValue(forKey: instance.id)
        try virtualizationService.stop(instance)
    }

    /// Immediately terminates the VM. Bypasses serialization so users can
    /// always force-kill, even during another in-flight operation. Clears the
    /// active-operation token *before* calling the service, invalidating any
    /// in-flight operation's defer guard.
    func forceStop(_ instance: VMInstance) async throws {
        activeOperations.removeValue(forKey: instance.id)
        try await virtualizationService.forceStop(instance)
    }

    func pause(_ instance: VMInstance) async throws {
        try await serialized(instance, action: "pause") {
            try await virtualizationService.pause(instance)
        }
    }

    func resume(_ instance: VMInstance) async throws {
        try await serialized(instance, action: "resume") {
            try await virtualizationService.resume(instance)
        }
    }

    func save(_ instance: VMInstance) async throws {
        try await serialized(instance, action: "save") {
            try await virtualizationService.save(instance)
        }
    }

    // MARK: - macOS Installation

    #if arch(arm64)
    func installMacOS(
        on instance: VMInstance,
        wizard: VMCreationViewModel,
        storageService: any VMStorageProviding
    ) async throws {
        try await serialized(instance, action: "installMacOS") {
            Self.logger.debug("installMacOS: entering for '\(instance.name, privacy: .public)', source=\(String(describing: wizard.ipswSource), privacy: .public)")
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
                Self.logger.info("macOS installation cancelled for '\(instance.name, privacy: .public)'")
            } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                Self.logger.info("IPSW download cancelled for '\(instance.name, privacy: .public)'")
            } catch {
                instance.status = .error
                instance.errorMessage = error.localizedDescription
                throw error
            }

            instance.installTask = nil
        }
    }
    #endif
}
