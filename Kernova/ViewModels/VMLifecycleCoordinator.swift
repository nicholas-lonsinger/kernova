import Foundation
import os

/// Coordinates VM lifecycle operations and macOS installation.
///
/// All methods re-throw errors — the caller is responsible for presentation.
///
/// Each VM can have at most one in-flight lifecycle operation at a time;
/// concurrent requests for the same VM are rejected with
/// ``LifecycleError/operationInProgress``. `stop` and `forceStop` bypass that
/// serialization entirely, so a hung operation can always be interrupted.
@MainActor
final class VMLifecycleCoordinator {
    private static let logger = Logger(subsystem: "app.kernova", category: "VMLifecycleCoordinator")

    let virtualizationService: any VirtualizationProviding
    let installService: any MacOSInstallProviding
    let ipswService: any IPSWProviding
    let usbDeviceService: any USBDeviceProviding

    /// The directory IPSW downloads must land in — the one location the
    /// sandbox's downloads entitlement covers.
    ///
    /// `nil` disables normalization.
    private let downloadsDirectory: URL?

    /// Maps VM ID → operation token for VMs that currently have a lifecycle operation in flight.
    ///
    /// The token allows `defer` blocks to avoid clobbering entries inserted by a later operation.
    private var activeOperations: [UUID: UUID] = [:]

    init(
        virtualizationService: any VirtualizationProviding,
        installService: any MacOSInstallProviding,
        ipswService: any IPSWProviding,
        usbDeviceService: any USBDeviceProviding = USBDeviceService(),
        downloadsDirectory: URL? = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask
        ).first
    ) {
        self.virtualizationService = virtualizationService
        self.installService = installService
        self.ipswService = ipswService
        self.usbDeviceService = usbDeviceService
        self.downloadsDirectory = downloadsDirectory
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

    func hasActiveOperation(for instanceID: UUID) -> Bool {
        activeOperations[instanceID] != nil
    }

    /// Removes any active-operation tracking for the given VM.
    ///
    /// Call when a VM is deleted to avoid stale entries in the dictionary.
    func clearActiveOperation(for instanceID: UUID) {
        activeOperations.removeValue(forKey: instanceID)
    }

    /// Executes `body` only if no other operation is already in flight for this VM.
    ///
    /// The `defer` removes the entry only if its token still matches, so a stale
    /// removal cannot clobber a token written by `stop`/`forceStop` or by a
    /// subsequent operation.
    private func serialized<T>(
        _ instance: VMInstance,
        action: String,
        body: () async throws -> T
    ) async throws -> T {
        guard activeOperations[instance.id] == nil else {
            Self.logger.warning(
                "Rejected \(action, privacy: .public) for '\(instance.name, privacy: .public)': operation already in progress"
            )
            throw LifecycleError.operationInProgress(vmName: instance.name)
        }

        let token = UUID()
        activeOperations[instance.id] = token
        defer {
            if activeOperations[instance.id] == token {
                activeOperations.removeValue(forKey: instance.id)
            }
        }

        Self.logger.debug(
            "Acquired operation lock for '\(instance.name, privacy: .public)' (action: \(action, privacy: .public))")
        return try await body()
    }

    // MARK: - Lifecycle

    func start(_ instance: VMInstance, bootIntoRecovery: Bool = false) async throws {
        try await serialized(instance, action: "start") {
            try await virtualizationService.start(instance, bootIntoRecovery: bootIntoRecovery)
        }
    }

    /// Requests a graceful stop.
    ///
    /// Bypasses serialization so users can always interrupt an in-progress
    /// operation, clearing the active-operation token *before* calling the
    /// service to invalidate any in-flight operation's defer guard.
    func stop(_ instance: VMInstance) throws {
        activeOperations.removeValue(forKey: instance.id)
        try virtualizationService.stop(instance)
    }

    /// Immediately terminates the VM.
    ///
    /// Bypasses serialization so users can always force-kill, even during
    /// another in-flight operation, clearing the active-operation token *before*
    /// calling the service to invalidate that operation's defer guard.
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

    /// The effective IPSW download destination for a persisted path: the path
    /// itself when it names a file directly inside `downloadsDirectory`,
    /// otherwise the destination `remoteURL` derives inside Downloads (the
    /// wizard default when there is no pinned URL).
    ///
    /// Downloads is the only destination the app supports — the sandbox
    /// entitlement covers it, resume sidecar included, with no per-pick grant.
    ///
    /// The replacement is built from the remote URL through
    /// ``RestoreImageFilename`` rather than from the persisted path, because
    /// both the path and the URL come out of a `config.json` a user can edit:
    /// only a filename this app derived is safe to append to Downloads.
    func normalizedDownloadDestination(
        for persisted: URL, remoteURL: URL? = nil
    ) -> URL {
        guard let downloads = downloadsDirectory else { return persisted }
        guard !isInsideDownloads(persisted) else { return persisted }
        let filename =
            remoteURL.map(RestoreImageFilename.destination(for:))
            ?? RestoreImageFilename.fallback
        return downloads.appendingPathComponent(filename)
    }

    /// Whether `candidate` names a file sitting directly in the Downloads
    /// directory, which the directory itself does not.
    ///
    /// Symlink-resolved because the sandbox container's `Downloads` and the real
    /// `~/Downloads` are the same directory spelled two ways. Always `true` when
    /// normalization is disabled.
    private func isInsideDownloads(_ candidate: URL) -> Bool {
        guard let downloads = downloadsDirectory else { return true }
        let downloadsPath = Self.canonicalPath(downloads)
        guard Self.canonicalPath(candidate) != downloadsPath else { return false }
        return Self.canonicalPath(candidate.deletingLastPathComponent()) == downloadsPath
    }

    /// A path with symlinks resolved, `..` collapsed and any trailing separator
    /// dropped, so two spellings of one location compare equal.
    private static func canonicalPath(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    func installMacOS(
        on instance: VMInstance,
        context: MacOSInstallContext
    ) async throws {
        try await serialized(instance, action: "installMacOS") {
            Self.logger.debug(
                "installMacOS: entering for '\(instance.name, privacy: .public)', source=\(context.source.rawValue, privacy: .public)"
            )

            do {
                let ipswURL: URL

                // Live for the install's duration when the local IPSW carries a
                // security bookmark — the context survives app relaunches, so the
                // wizard's panel grant is long gone. The download path needs no
                // scope; its destination is entitlement-covered Downloads.
                var localIPSWScope: ScopedAccess?
                defer { localIPSWScope?.release() }

                switch context.source {
                case .downloadLatest, .catalogVersion, .customURL:
                    guard let persistedDestination = context.downloadDestinationURL else {
                        throw IPSWError.noDownloadURL
                    }
                    // A persisted destination outside Downloads (a hand-edited
                    // config.json) can never be written and has no picker to
                    // re-point it, so the invariant is enforced at use time.
                    let downloadDestination = normalizedDownloadDestination(
                        for: persistedDestination, remoteURL: context.remoteURL)
                    if downloadDestination != persistedDestination {
                        Self.logger.notice(
                            "installMacOS: persisted download destination is outside Downloads; using the derived destination instead"
                        )
                    }

                    // Honor "Download & Replace" intent ONCE: the download
                    // trashes the existing IPSW and any bundle beside it while
                    // holding its per-destination claim — trashing from out here
                    // could delete bytes another VM is streaming into the same
                    // bundle. The flag clears before the download so a retry
                    // after a partial-install failure reuses what it fetched.
                    if context.requestedFreshDownload {
                        // `downloadDestinationPath` survives through `config.json`
                        // on disk, so a stray edit could otherwise have us
                        // trashing an arbitrary file.
                        guard downloadDestination.pathExtension.lowercased() == "ipsw" else {
                            Self.logger.error(
                                "installMacOS: refusing to honor requestedFreshDownload for non-IPSW destination '\(downloadDestination.path(percentEncoded: false), privacy: .public)'"
                            )
                            throw IPSWError.invalidDownloadDestination(
                                path: downloadDestination.path(percentEncoded: false)
                            )
                        }

                        Self.logger.notice(
                            "installMacOS: honoring requestedFreshDownload for '\(instance.name, privacy: .public)' — the existing IPSW + bundle are trashed before the download starts"
                        )
                        instance.performConfigurationMutation {
                            $0.installContext?.requestedFreshDownload = false
                        }
                    }

                    instance.installState = MacOSInstallState(
                        hasDownloadStep: true,
                        currentPhase: .downloading(.zero)
                    )
                    instance.status = .installing

                    // A catalog pick or a checked URL names its image at wizard
                    // time, so the install downloads that build however long it
                    // sits unstarted. Only "Download Latest" resolves here.
                    let remoteURL: URL
                    if context.source.usesPinnedURL {
                        guard let pinnedURL = context.remoteURL else {
                            throw IPSWError.noDownloadURL
                        }
                        remoteURL = pinnedURL
                    } else {
                        remoteURL = try await ipswService.fetchLatestRestoreImage().url
                    }

                    try await ipswService.downloadRestoreImage(
                        from: remoteURL,
                        to: downloadDestination,
                        discardsExistingDownload: context.requestedFreshDownload
                    ) { progress in
                        instance.installState?.currentPhase = .downloading(progress)
                    }

                    instance.installState?.downloadCompleted = true
                    instance.installState?.currentPhase = .installing(progress: 0)
                    ipswURL = downloadDestination

                case .localFile:
                    guard let localURL = context.localIPSWURL else {
                        throw IPSWError.noDownloadURL
                    }
                    localIPSWScope = context.localIPSWBookmark.flatMap {
                        ScopedAccess(bookmark: $0)
                    }
                    // Prefer the bookmark's resolved URL — it tracks the file if
                    // it moved since the wizard pick.
                    ipswURL = localIPSWScope?.url ?? localURL
                    // The context survives relaunches until the install succeeds,
                    // so its bookmark can go stale between retries.
                    if let scope = localIPSWScope, scope.isStale,
                        let fresh = SecurityScopedBookmark.make(for: scope.url)
                    {
                        instance.performConfigurationMutation {
                            $0.installContext?.localIPSWBookmark = fresh
                        }
                    }

                    instance.installState = MacOSInstallState(
                        hasDownloadStep: false,
                        currentPhase: .installing(progress: 0)
                    )
                    instance.status = .installing
                }

                try await installService.install(
                    into: instance,
                    restoreImageURL: ipswURL
                ) { @MainActor progress in
                    instance.installState?.currentPhase = .installing(progress: progress)
                }

                // Clear the persisted install intent so subsequent Starts take the
                // normal boot path, and clear `installState` so the progress UI
                // tears down before the caller chains an auto-boot.
                instance.performConfigurationMutation { $0.installContext = nil }
                instance.installState = nil
            } catch is CancellationError {
                Self.logger.info("macOS installation cancelled for '\(instance.name, privacy: .public)'")
                // Re-throw so the caller knows to flip the VM back to
                // .initialBoot rather than auto-booting on a non-success.
                throw CancellationError()
            } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                Self.logger.info("IPSW download cancelled for '\(instance.name, privacy: .public)'")
                // Normalize to CancellationError for consistent caller-side handling.
                throw CancellationError()
            } catch {
                let nsError = error as NSError
                Self.logger.error(
                    "Install failed for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public) [\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public); underlying: \(VirtualizationService.underlyingChainDescription(nsError), privacy: .public)]"
                )
                if VirtualizationService.isTransientStartError(error) {
                    instance.errorMessage = nil
                    instance.status = .initialBoot
                } else {
                    instance.status = .error
                    instance.errorMessage = error.localizedDescription
                }
                throw error
            }
        }
    }

    // MARK: - USB Device Management

    /// Attaches a USB mass storage device to a running VM and appends it to
    /// `instance.liveRemovableMedia`.
    ///
    /// `desiredUUID` overrides the framework-generated
    /// `VZUSBDeviceConfiguration.uuid` so the runtime device matches the caller's
    /// persisted identity, which save-state restore matches on. `resolvedURL`,
    /// when supplied, is what actually gets attached, while the *tracked* identity
    /// stays `diskImagePath`.
    func attachUSBDevice(
        diskImagePath: String,
        readOnly: Bool,
        desiredUUID: UUID? = nil,
        resolvedURL: URL? = nil,
        to instance: VMInstance
    ) async throws -> USBDeviceInfo {
        let info = try await usbDeviceService.attach(
            diskImagePath: resolvedURL?.path(percentEncoded: false) ?? diskImagePath,
            readOnly: readOnly,
            desiredUUID: desiredUUID,
            to: instance
        )
        let tracked = USBDeviceInfo(
            id: info.id, path: diskImagePath, readOnly: info.readOnly,
            attachedAt: info.attachedAt)
        instance.liveRemovableMedia.append(tracked)
        return tracked
    }

    func detachUSBDevice(_ deviceInfo: USBDeviceInfo, from instance: VMInstance) async throws {
        try await usbDeviceService.detach(deviceInfo: deviceInfo, from: instance)
        instance.liveRemovableMedia.removeAll { $0.id == deviceInfo.id }
    }
}
