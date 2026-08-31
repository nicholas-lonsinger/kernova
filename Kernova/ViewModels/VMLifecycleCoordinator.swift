import Foundation
import os

/// Coordinates VM lifecycle operations and the guest-setup pipelines — a macOS
/// install, and a Linux installer image fetched, checked against whatever
/// digest stands behind it, and attached.
///
/// All methods re-throw errors — the caller is responsible for presentation.
///
/// Each VM can have at most one in-flight lifecycle operation at a time;
/// concurrent requests for the same VM are rejected with
/// ``LifecycleError/operationInProgress``. `stop` and `forceStop` bypass that
/// serialization entirely, so a hung operation can always be interrupted.
@MainActor
@Observable
final class VMLifecycleCoordinator {
    private static let logger = Logger(subsystem: "app.kernova", category: "VMLifecycleCoordinator")

    let virtualizationService: any VirtualizationProviding
    let installService: any MacOSInstallProviding
    let ipswService: any IPSWProviding
    let usbDeviceService: any USBDeviceProviding
    let linuxImageResolveService: any LinuxImageResolving
    let downloadService: any Downloading

    /// Trashes an image that failed verification.
    private let fileSystem: any FileSystemOperating

    /// The directory downloads must land in — the one location the sandbox's
    /// downloads entitlement covers.
    ///
    /// `nil` disables normalization.
    private let downloadsDirectory: URL?

    /// Maps VM ID → operation token for VMs that currently have a lifecycle operation in flight.
    ///
    /// The token allows `defer` blocks to avoid clobbering entries inserted by a later operation.
    private var activeOperations: [UUID: UUID] = [:]

    /// Maps VM ID → the number of ``serialized`` bodies still executing for it.
    ///
    /// Counted rather than flagged: `stop` and `forceStop` clear a claim without
    /// stopping the body that held it, so a second operation can acquire the
    /// claim and run alongside the first. Each body clears its own entry.
    private var unsettledOperations: [UUID: Int] = [:]

    init(
        virtualizationService: any VirtualizationProviding,
        installService: any MacOSInstallProviding,
        ipswService: any IPSWProviding,
        usbDeviceService: any USBDeviceProviding = USBDeviceService(),
        linuxImageResolveService: any LinuxImageResolving = LinuxImageResolveService(),
        downloadService: any Downloading = DownloadService(),
        fileSystem: any FileSystemOperating = FileManager.default,
        downloadsDirectory: URL? = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask
        ).first
    ) {
        self.virtualizationService = virtualizationService
        self.installService = installService
        self.ipswService = ipswService
        self.usbDeviceService = usbDeviceService
        self.linuxImageResolveService = linuxImageResolveService
        self.downloadService = downloadService
        self.fileSystem = fileSystem
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

    /// Whether a serialized operation currently *claims* this VM — the read that
    /// decides whether a new request is rejected.
    func hasActiveOperation(for instanceID: UUID) -> Bool {
        activeOperations[instanceID] != nil
    }

    /// Whether any serialized operation for this VM is still running its body,
    /// and so may still have a VZ call in flight.
    ///
    /// Distinct from ``hasActiveOperation(for:)``, which tracks the claim:
    /// `stop` and `forceStop` release another operation's claim so a user can
    /// always interrupt, but the interrupted body keeps running. A caller
    /// deciding whether it may issue its *own* VZ operation therefore asks this,
    /// not the claim, or it acts while VZ is still busy.
    ///
    /// Observable, so a `withObservationTracking` wait on it wakes when the
    /// operation ends — which is what lets a caller hold for an operation whose
    /// ``VMStatus`` never changes (a pause settles at `.running`, a resume at
    /// `.paused`).
    func hasUnsettledOperation(for instanceID: UUID) -> Bool {
        unsettledOperations[instanceID] != nil
    }

    /// Removes any active-operation tracking for the given VM.
    ///
    /// Call when a VM is deleted to avoid stale entries in the dictionary.
    func clearActiveOperation(for instanceID: UUID) {
        activeOperations.removeValue(forKey: instanceID)
    }

    /// Executes `body` only if no other operation is already in flight for this VM.
    ///
    /// The `defer` removes the claim only if its token still matches, so a stale
    /// removal cannot clobber a token written by `stop`/`forceStop` or by a
    /// subsequent operation. The unsettled count is dropped unconditionally,
    /// because it tracks *this* body and nothing else can end it.
    private func serialized<T>(
        _ instance: VMInstance,
        action: String,
        body: () async throws -> T
    ) async throws -> T {
        guard !hasActiveOperation(for: instance.id) else {
            Self.logger.warning(
                "Rejected \(action, privacy: .public) for '\(instance.name, privacy: .public)': operation already in progress"
            )
            throw LifecycleError.operationInProgress(vmName: instance.name)
        }

        let token = UUID()
        activeOperations[instance.id] = token
        unsettledOperations[instance.id, default: 0] += 1
        defer {
            if activeOperations[instance.id] == token {
                activeOperations.removeValue(forKey: instance.id)
            }
            let remaining = (unsettledOperations[instance.id] ?? 1) - 1
            unsettledOperations[instance.id] = remaining > 0 ? remaining : nil
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
    func stop(_ instance: VMInstance) async throws {
        activeOperations.removeValue(forKey: instance.id)
        try await virtualizationService.stop(instance)
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

    // MARK: - Snapshots

    func takeSnapshot(
        _ instance: VMInstance, snapshot: VMSnapshot, store: any VMSnapshotStoring
    ) async throws {
        try await serialized(instance, action: "takeSnapshot") {
            try await virtualizationService.takeSnapshot(instance, snapshot: snapshot, store: store)
        }
    }

    func revertToSnapshot(
        _ instance: VMInstance, snapshot: VMSnapshot, store: any VMSnapshotStoring
    ) async throws {
        try await serialized(instance, action: "revertToSnapshot") {
            try await virtualizationService.revertToSnapshot(
                instance, snapshot: snapshot, store: store)
        }
    }

    /// Moves one snapshot's captured files to the Trash.
    ///
    /// Serialized like the operations that read those files, so a delete cannot
    /// run while a revert is copying out of the same directory.
    func discardSnapshot(
        _ instance: VMInstance, snapshotID: UUID, store: any VMSnapshotStoring
    ) async throws {
        let bundleURL = instance.bundleURL
        try await serialized(instance, action: "discardSnapshot") {
            try await Task.detached {
                try store.discardSnapshot(bundleURL: bundleURL, snapshotID: snapshotID)
            }.value
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

    /// The destination a "Download Latest" install writes to, named by the URL
    /// the install just resolved.
    ///
    /// The persisted path is only the wizard's preview of that answer: the
    /// newest build can move between wizard and Start, and only a name derived
    /// from the URL actually fetched keeps ``RestoreImageFilename``'s per-build
    /// identity honest for the file the bytes land in. Falls back to the
    /// persisted path when normalization is disabled.
    func latestDownloadDestination(persisted: URL, resolvedURL: URL) -> URL {
        guard let downloads = downloadsDirectory else { return persisted }
        return downloads.appendingPathComponent(
            RestoreImageFilename.destination(for: resolvedURL))
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

                    instance.setupState = .macOSInstall(hasDownloadStep: true)
                    instance.status = .installing

                    // Local because a moved latest destination lapses it below.
                    var requestedFreshDownload = context.requestedFreshDownload

                    // A catalog pick or a checked URL names its image and its
                    // destination at wizard time, so the install downloads that
                    // build however long it sits unstarted. Only "Download
                    // Latest" resolves here, and its destination follows the
                    // answer.
                    let remoteURL: URL
                    let downloadDestination: URL
                    if context.source.usesPinnedURL {
                        guard let pinnedURL = context.remoteURL else {
                            throw IPSWError.noDownloadURL
                        }
                        remoteURL = pinnedURL
                        // A persisted destination outside Downloads (a hand-edited
                        // config.json) can never be written and has no picker to
                        // re-point it, so the invariant is enforced at use time.
                        downloadDestination = normalizedDownloadDestination(
                            for: persistedDestination, remoteURL: remoteURL)
                        if downloadDestination != persistedDestination {
                            Self.logger.notice(
                                "installMacOS: persisted download destination is outside Downloads; using the derived destination instead"
                            )
                        }
                    } else {
                        remoteURL = try await ipswService.fetchLatestRestoreImage().url
                        downloadDestination = latestDownloadDestination(
                            persisted: persistedDestination, resolvedURL: remoteURL)
                        if downloadDestination != persistedDestination {
                            Self.logger.notice(
                                "installMacOS: resolved latest image names the download '\(downloadDestination.lastPathComponent, privacy: .public)'"
                            )
                            // "Download & Replace" was confirmed against the
                            // wizard's destination; a destination that moved
                            // names a file the user never saw, so the intent
                            // lapses rather than retargets.
                            requestedFreshDownload = false
                            // A moved destination also means the fetch changed
                            // builds, so the old path's partial download can
                            // never be resumed — discard its sidecar before the
                            // only pointer to it moves.
                            ipswService.discardResumeData(
                                at: persistedDestination, permanently: false)
                            // Keep the persisted path on the file the download
                            // actually writes, so resume across relaunches and
                            // delete-time cleanup stay keyed to it.
                            instance.performConfigurationMutation {
                                $0.installContext?.downloadDestinationPath =
                                    downloadDestination.path(percentEncoded: false)
                                $0.installContext?.requestedFreshDownload = false
                            }
                        }
                    }

                    // Honor "Download & Replace" intent ONCE: the download
                    // trashes the existing IPSW and any bundle beside it while
                    // holding its per-destination claim — trashing from out here
                    // could delete bytes another VM is streaming into the same
                    // bundle. The flag clears before the download so a retry
                    // after a partial-install failure reuses what it fetched.
                    if requestedFreshDownload {
                        // `downloadDestinationPath` survives through `config.json`
                        // on disk, so a stray edit could otherwise have us
                        // trashing an arbitrary file.
                        guard downloadDestination.pathExtension.lowercased() == "ipsw" else {
                            Self.logger.error(
                                "installMacOS: refusing to honor requestedFreshDownload for non-IPSW destination '\(downloadDestination.path(percentEncoded: false), privacy: .public)'"
                            )
                            throw DownloadError.invalidDownloadDestination(
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

                    try await ipswService.downloadRestoreImage(
                        from: remoteURL,
                        to: downloadDestination,
                        discardsExistingDownload: requestedFreshDownload
                    ) { progress in
                        instance.setupState?.progress = .download(progress)
                    }

                    instance.setupState?.advance(progress: .fraction(0))
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

                    instance.setupState = .macOSInstall(hasDownloadStep: false)
                    instance.status = .installing
                }

                let installedImage = try await installService.install(
                    into: instance,
                    restoreImageURL: ipswURL
                ) { @MainActor progress in
                    instance.setupState?.progress = .fraction(progress)
                }

                // Clear the persisted install intent so subsequent Starts take the
                // normal boot path, record the image this VM now carries, and
                // clear `setupState` so the progress UI tears down before the
                // caller chains an auto-boot.
                instance.performConfigurationMutation {
                    $0.installContext = nil
                    $0.installedImage = installedImage
                }
                instance.setupState = nil
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
                VirtualizationService.applyStartFailure(
                    error, to: instance, transientRestingStatus: .initialBoot)
                throw error
            }
        }
    }

    // MARK: - Linux Installer Image

    /// Where a resolved Linux image is written: inside Downloads, under the
    /// name ``LinuxImageFilename`` derives for the URL it resolved to.
    ///
    /// Never built from the persisted path, which comes out of a `config.json`
    /// a user can edit, and never from a name the source chose: only a name
    /// this app derived is safe to append to a directory holding everything the
    /// user has ever downloaded.
    ///
    /// Falls back to the persisted path when normalization is disabled, and
    /// only while it still names an ISO — the download writes over this path,
    /// and a digest failure trashes it, so an edit pointing it at an arbitrary
    /// file names no destination at all.
    func linuxDownloadDestination(persisted: URL?, filename: String) -> URL? {
        guard let downloads = downloadsDirectory else {
            guard persisted?.pathExtension.lowercased() == "iso" else { return nil }
            return persisted
        }
        return downloads.appendingPathComponent(filename)
    }

    /// Adopts a file already in Downloads under the name the source published,
    /// when its bytes hash to the digest published for it.
    ///
    /// A browser — or an app release predating the discriminated destination —
    /// writes the ISO under the mirror's own name, where nothing later finds
    /// it and the same gigabytes are fetched again. Nothing here rests on that
    /// name: it selects a candidate and decides nothing, the file is admitted
    /// only by its length and its SHA-256 matching what the source states, and
    /// adoption hard-links it to the discriminated destination rather than
    /// installing it in place, so the user's own entry stays untouched and
    /// every later step reads the one file this pipeline names.
    ///
    /// `false` whenever the candidate cannot be shown to be the image — the
    /// ordinary download, and the only outcome when the source publishes no
    /// digest to check against.
    private func adoptLocalImage(
        _ image: ResolvedLinuxImage, as destination: URL
    ) async throws -> Bool {
        guard let downloads = downloadsDirectory, let expected = image.sha256?.lowercased() else {
            return false
        }
        // A file already at the destination belongs to the download: it skips
        // over it and the verify step below holds it to this same digest. An
        // adoption is refused there in any case — asked before the hash rather
        // than after it, so a second VM built from one catalog entry does not
        // read gigabytes to reach a refusal. Read from the filesystem the rest
        // of this probe reads, not the trash seam.
        guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false))
        else { return false }

        // Re-admitted at the point it is appended to a directory: this is the
        // one place a name the source chose reaches the filesystem.
        guard let candidateName = SafeFilename.sanitized(image.filename, requiring: "iso") else {
            return false
        }
        let candidate = downloads.appendingPathComponent(candidateName)
        // A source is free to publish a name already shaped like a
        // discriminated one; a file may not be linked onto itself.
        guard candidate.standardizedFileURL != destination.standardizedFileURL else { return false }

        // The length the mirror states, checked with a stat before gigabytes
        // are read: a truncated or unrelated file under the same name costs
        // nothing to reject, so the hash below essentially only runs on a file
        // that will match.
        let values = try? candidate.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values?.isRegularFile == true, values?.isSymbolicLink == false,
            values?.fileSize.map(UInt64.init(clamping:)) == image.sizeBytes
        else { return false }

        Self.logger.notice(
            "downloadLinuxImage: hashing '\(candidateName, privacy: .public)', already in Downloads, against the digest published for it"
        )
        let digest: String
        do {
            digest = try await FileDigest.sha256(of: candidate) { _ in }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.warning(
                "downloadLinuxImage: could not hash '\(candidateName, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        guard digest == expected else {
            Self.logger.notice(
                "downloadLinuxImage: '\(candidateName, privacy: .public)' hashes to \(digest, privacy: .public), not the published \(expected, privacy: .public) — downloading"
            )
            return false
        }
        return await downloadService.adoptExistingFile(at: candidate, as: destination)
    }

    /// Fetches the Linux installer image `context` names, checks it against the
    /// digest published or supplied for it, and attaches it as the VM's boot
    /// media.
    ///
    /// Every step is re-entrant: a cancelled or failed attempt leaves the
    /// context in place, so the next Start resolves again and resumes from
    /// whatever partial bytes are on disk.
    func downloadLinuxImage(
        on instance: VMInstance,
        context: LinuxInstallContext
    ) async throws {
        try await serialized(instance, action: "downloadLinuxImage") {
            Self.logger.debug(
                "downloadLinuxImage: entering for '\(instance.name, privacy: .public)', image=\(context.imageDisplayName, privacy: .public)"
            )

            do {
                instance.setupState = .linuxImage(hasVerifyStep: context.hasVerifyStep)
                instance.status = .installing

                // Resolved on every attempt: a catalog entry because the mirror
                // renames its ISO in place (see `LinuxImageCatalogEntry`), a
                // pasted URL because the size it answers with is the ceiling
                // this transfer is held to.
                let image: ResolvedLinuxImage
                switch context.source {
                case .catalogEntry(let entry):
                    image = try await linuxImageResolveService.resolve(entry)
                case .customURL(let custom):
                    image = try await linuxImageResolveService.resolve(custom)
                }

                // `image.destinationFilename`, never the name the source gave
                // the ISO: Downloads holds everything the user has ever
                // fetched, and a file already sitting under the source's name
                // is one the download would adopt in place of fetching, or
                // trash for failing a digest that was never its own.
                guard
                    let downloadDestination = linuxDownloadDestination(
                        persisted: context.downloadDestinationURL,
                        filename: image.destinationFilename)
                else {
                    throw DownloadError.invalidDownloadDestination(
                        path: context.downloadDestinationURL?.path(percentEncoded: false)
                            ?? image.destinationFilename)
                }

                if let persisted = context.downloadDestinationURL,
                    persisted != downloadDestination
                {
                    Self.logger.notice(
                        "downloadLinuxImage: the resolution moved to '\(image.filename, privacy: .public)', downloading to '\(downloadDestination.lastPathComponent, privacy: .public)'"
                    )
                    // The partial at the abandoned path belongs to an image
                    // this download is no longer fetching, so discard it before
                    // the only pointer to it moves.
                    downloadService.discardResumeData(at: persisted, permanently: false)
                }
                // Keep the persisted path on the file the download writes, so
                // resume across relaunches and delete-time cleanup stay keyed
                // to it.
                instance.performConfigurationMutation {
                    $0.linuxInstallContext?.downloadDestinationPath =
                        downloadDestination.path(percentEncoded: false)
                }

                // The mirror's own size, so the bar reads against the whole
                // file from the first sample; the transfer's `Content-Length`
                // governs once bytes are moving.
                instance.setupState?.progress = .download(
                    DownloadProgress(
                        bytesWritten: 0,
                        totalBytes: Int64(clamping: image.sizeBytes),
                        bytesPerSecond: 0))

                // The Download step reports nothing while the probe runs: it
                // reads a file the user already has and fetches none of the
                // bytes the bar counts. The seeded `0 B / <size>` above is what
                // a transfer opening its connection shows too.
                if try await adoptLocalImage(image, as: downloadDestination) {
                    // The digest decided the adoption, so Verify has nothing
                    // left to check and the step is drawn finished.
                    if context.hasVerifyStep {
                        instance.setupState?.advance(progress: .fraction(1))
                    }
                } else {
                    // Never replaces: the destination is named for this URL, so
                    // a file already there is what a prior attempt at this same
                    // image fetched, and adopting it is right — the verify step
                    // below holds it to the same digest a fresh download would
                    // face.
                    try await downloadService.download(
                        from: image.isoURL,
                        to: downloadDestination,
                        discardsExistingDownload: false,
                        expectedSizeBytes: image.sizeBytes
                    ) { progress in
                        instance.setupState?.progress = .download(progress)
                    }

                    // Runs whether the bytes were just fetched or the download
                    // skipped over a file already sitting complete at the
                    // destination: an image nothing has checked is an image
                    // that could install anything. A pasted URL with no digest
                    // behind it has nothing to check against, and the wizard
                    // said so.
                    if let expected = image.sha256?.lowercased() {
                        instance.setupState?.advance(progress: .fraction(0))
                        let digest = try await FileDigest.sha256(of: downloadDestination) {
                            fraction in
                            instance.setupState?.progress = .fraction(fraction)
                        }
                        guard digest == expected else {
                            Self.logger.error(
                                "downloadLinuxImage: '\(image.filename, privacy: .public)' hashes to \(digest, privacy: .public), not the expected \(expected, privacy: .public)"
                            )
                            discardUnverifiedImage(at: downloadDestination)
                            throw DownloadError.checksumMismatch(
                                filename: image.filename, expected: expected, actual: digest)
                        }
                    }
                }

                attachInstallerImage(
                    at: downloadDestination, named: image.filename,
                    from: InstalledImage(linuxSource: context.source), to: instance)
                instance.setupState = nil
                // The VM entered `.installing` for the pipeline and nothing
                // else takes it out — unlike a macOS install, no VZ session ran
                // to leave it `.stopped`. The caller chains a Start straight
                // off this return, and `.installing` fails its guard.
                instance.status = .stopped
            } catch is CancellationError {
                Self.logger.info(
                    "Linux image download cancelled for '\(instance.name, privacy: .public)'")
                // Re-thrown so the caller flips the VM back to .initialBoot
                // rather than auto-booting on a non-success.
                throw CancellationError()
            } catch let error as NSError
                where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
            {
                Self.logger.info(
                    "Linux image download cancelled for '\(instance.name, privacy: .public)'")
                // Normalize to CancellationError for consistent caller-side handling.
                throw CancellationError()
            } catch {
                let nsError = error as NSError
                Self.logger.error(
                    "Linux image download failed for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public) [\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)]"
                )
                VirtualizationService.applyStartFailure(
                    error, to: instance, transientRestingStatus: .initialBoot)
                throw error
            }
        }
    }

    /// Trashes an image whose digest did not match, and any resume bundle left
    /// beside it.
    ///
    /// Left in place, the file would satisfy the download's skip-existing fast
    /// path on every retry and the VM could never reach a good copy.
    private func discardUnverifiedImage(at destination: URL) {
        do {
            try fileSystem.trashItem(at: destination)
            Self.logger.notice(
                "Trashed '\(destination.lastPathComponent, privacy: .public)' — it did not match its expected checksum"
            )
        } catch {
            Self.logger.warning(
                "Failed to trash the unverified image at '\(destination.path(percentEncoded: false), privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
        downloadService.discardResumeData(at: destination, permanently: false)
    }

    /// Attaches the fetched installer image ahead of the VM's main disk,
    /// records `installedImage` as what the VM was set up from, and clears the
    /// pending download intent.
    ///
    /// `filename` is the name the source gave the ISO, which is what the disk
    /// is labelled with — the file it was written to carries a discriminator
    /// suffix no user would recognize.
    ///
    /// The bookmark is minted without a panel — Downloads is covered by the
    /// downloads entitlement — and it is worth minting because, unlike an IPSW
    /// consumed by an install, this attachment outlives the setup and has to
    /// track the file if the user later moves it.
    private func attachInstallerImage(
        at destination: URL, named filename: String, from installedImage: InstalledImage?,
        to instance: VMInstance
    ) {
        let installer = StorageDisk(
            path: destination.path(percentEncoded: false),
            readOnly: true,
            label: (filename as NSString).deletingPathExtension,
            bookmark: SecurityScopedBookmark.make(for: destination)
        )
        let layout = VMBundleLayout(bundleURL: instance.bundleURL)
        instance.performConfigurationMutation { config in
            // Position [0] is what EFI boots first, which is the whole reason
            // the installer is on the list at all.
            config.storageDisks =
                [installer]
                + (config.storageDisks ?? [ConfigurationBuilder.defaultMainDisk(layout: layout)])
            config.linuxInstallContext = nil
            config.installedImage = installedImage
        }
        Self.logger.notice(
            "Attached installer image '\(destination.lastPathComponent, privacy: .public)' to '\(instance.name, privacy: .public)'"
        )
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
        instance.sessionContext?.liveRemovableMedia.append(tracked)
        return tracked
    }

    func detachUSBDevice(_ deviceInfo: USBDeviceInfo, from instance: VMInstance) async throws {
        try await usbDeviceService.detach(deviceInfo: deviceInfo, from: instance)
        instance.sessionContext?.liveRemovableMedia.removeAll { $0.id == deviceInfo.id }
    }
}
