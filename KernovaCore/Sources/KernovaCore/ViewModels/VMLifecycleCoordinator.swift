import Foundation
import KernovaLogging

/// Runs the lifecycle operations and the guest-setup pipelines — a macOS
/// install, and a Linux installer image fetched, checked against whatever
/// digest stands behind it, and attached — each inside the operation its VM's
/// ``VMActivity`` admits.
///
/// All methods re-throw errors — the caller is responsible for presentation.
@MainActor
final class VMLifecycleCoordinator {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMLifecycleCoordinator")

    let virtualizationService: any VirtualizationProviding
    let installService: any MacOSInstallProviding
    let ipswService: any IPSWProviding
    let removableMediaDeviceService: any RemovableMediaAttaching
    /// Swaps a running macOS guest's shares on its directory-sharing device.
    let liveDirectorySharing = LiveDirectoryShareService()
    let linuxImageResolveService: any LinuxImageResolving
    let downloadService: any Downloading

    /// Whether this process can pass host USB accessories through to a guest,
    /// and if not, why.
    let usbAccessoryPassthrough: USBAccessoryPassthrough

    /// Passes host USB accessories through to a guest, or `nil` when
    /// passthrough is unavailable.
    var usbAccessoryService: (any USBAccessoryProviding)? { usbAccessoryPassthrough.service }

    /// Trashes what the user can see: an image that failed verification, the
    /// original of a config file Use Defaults rewrote.
    let fileSystem: any FileSystemOperating

    /// The directory downloads must land in — the one location the sandbox's
    /// downloads entitlement covers.
    let downloadsDirectory: URL

    init(
        virtualizationService: any VirtualizationProviding,
        installService: any MacOSInstallProviding,
        ipswService: any IPSWProviding,
        removableMediaDeviceService: any RemovableMediaAttaching,
        usbAccessoryPassthrough: USBAccessoryPassthrough,
        linuxImageResolveService: any LinuxImageResolving = LinuxImageResolveService(),
        downloadService: any Downloading = DownloadService(),
        fileSystem: any FileSystemOperating = FileManager.default,
        downloadsDirectory: URL = UserDownloads.url
    ) {
        self.virtualizationService = virtualizationService
        self.installService = installService
        self.ipswService = ipswService
        self.removableMediaDeviceService = removableMediaDeviceService
        self.usbAccessoryPassthrough = usbAccessoryPassthrough
        self.linuxImageResolveService = linuxImageResolveService
        self.downloadService = downloadService
        self.fileSystem = fileSystem
        self.downloadsDirectory = downloadsDirectory
    }

    // MARK: - Lifecycle

    /// Launches the bring-up the guest start `kind` names on `instance`,
    /// resolving `outcome` when it ends.
    ///
    /// `beforeBoot` runs first, as a write of the start. `afterBoot` runs once
    /// the guest came up, as a write of the start too, with the route it came
    /// up by; what it throws fails the start and leaves the guest where the
    /// boot left it.
    @discardableResult
    func launchStart(
        _ instance: VMInstance, _ kind: VMGuestStartKind,
        identity: VMIdentityOverride = .unavailable,
        provisioning: GuestProvisioningCredentials? = nil,
        resolving outcome: VMOutcome = VMOutcome(),
        beforeBoot: @escaping @MainActor (borrowing VMEditPermit) -> Void = { _ in },
        afterBoot: @escaping @MainActor (borrowing VMEditPermit, GuestStartRoute) throws -> Void = {
            _, _ in
        }
    ) throws -> VMOutcome {
        try instance.activity.launchStartGuest(kind, identity: identity, resolving: outcome) {
            [virtualizationService] context in
            beforeBoot(context.bringUp.operation.permit)
            let ending = try await virtualizationService.start(
                instance, context, provisioning: provisioning)
            switch ending {
            case .rest(let rest, let route):
                do { try afterBoot(context.bringUp.operation.permit, route) } catch {
                    return .failed(rest, error)
                }
                return .rest(rest, ())
            case .failed(let rest, let error):
                return .failed(rest, error)
            }
        }
    }

    /// Requests a graceful stop — a session action, which takes no admission
    /// of its own, so an operation that tolerates it keeps holding the VM.
    func requestStop(_ instance: VMInstance) async throws {
        try await instance.activity.requestStop {
            try await virtualizationService.requestStop(instance)
        }
    }

    /// A Restart's graceful stop, owing `boot` to the end of the session it
    /// asks to go down — see ``VMActivity/requestStop(continuingWith:_:)``.
    func requestRestartStop(_ instance: VMInstance, continuingWith boot: VMFollowUp) async throws {
        try await instance.activity.requestStop(continuingWith: boot) {
            try await virtualizationService.requestStop(instance)
        }
    }

    /// Immediately terminates the VM — see ``VMActivity/forceStop(_:)``.
    func forceStop(_ instance: VMInstance) async throws {
        try await instance.activity.forceStop {
            try await virtualizationService.forceStop(instance)
        }
    }

    /// Ends the suspension the bundle holds: the saved state goes, and the VM
    /// rests stopped.
    ///
    /// The two are one operation because a suspension whose slot is gone is a
    /// dead end — Resume has nothing to load and the settings stay locked
    /// behind a file that is not there. A removal the file system turned down
    /// leaves the VM resting on the slot it still holds and throws
    /// ``VirtualizationError/savedStateNotDiscarded``.
    ///
    /// `before` runs first, as a write of the discard: what throws there
    /// leaves the saved state in place.
    func discardSavedState(
        _ instance: VMInstance, before: (borrowing VMEditPermit) throws -> Void = { _ in }
    ) throws {
        try instance.activity.performNow(.discardingSavedState) {
            (context: borrowing VMOperationContext) -> VMOperationEnding<Void> in
            try before(context.permit)
            context.bundle.removeSaveFile()
            guard !context.bundle.hasSaveFile else {
                return .failed(.asStarted, VirtualizationError.savedStateNotDiscarded)
            }
            Self.logger.log(
                .notice,
                "Discarded saved state for VM '\(instance.name, privacy: .public)'")
            return .rest(.atRest(.stopped), ())
        }
    }

    func pause(_ instance: VMInstance) async throws {
        try await instance.activity.perform(.pausing) { context in
            try await virtualizationService.pause(instance, context)
        }
    }

    /// ``pause(_:)`` as an operation no caller has to wait on, resolving
    /// `outcome` — admitted and committed before this returns, and throwing
    /// the refusal otherwise.
    func launchPause(_ instance: VMInstance, resolving outcome: VMOutcome) throws {
        try instance.activity.launch(.pausing, resolving: outcome) {
            [virtualizationService] context in
            try await virtualizationService.pause(instance, context)
        }
    }

    /// Launches the resume of a live-paused VM from memory, resolving
    /// `outcome` when it ends — admitted and committed before this returns,
    /// and throwing the refusal otherwise.
    @discardableResult
    func launchResume(_ instance: VMInstance, resolving outcome: VMOutcome = VMOutcome()) throws -> VMOutcome {
        try instance.activity.launch(.resuming, resolving: outcome) {
            [virtualizationService] context in
            try await virtualizationService.resume(instance, context)
        }
    }

    /// Suspends the VM to disk.
    ///
    /// The accessories the write ejects stay off, on both outcomes: the guest
    /// is going away, and a suspend that fails takes the session down with it,
    /// so there is no guest left to put anything back on. A suspend refused
    /// because its state would not restore
    /// (``VMLiveStateCapture/SaveRefusal``) touches nothing first, and leaves
    /// the guest running.
    func save(_ instance: VMInstance, origin: VMRequestOrigin = .newWork) async throws {
        try await instance.activity.perform(.saving, origin: origin) { context in
            try await virtualizationService.save(instance, context)
        }
    }

    // MARK: - Snapshots

    /// Captures `snapshot` in `mode` and lists it with `record`, inside one
    /// capture operation, which ends once the snapshot's files are written.
    ///
    /// A warm capture takes every passthrough accessory off before it writes
    /// the guest's state, for the reason
    /// ``VMLiveStateCapture/suspendState(_:session:to:)`` gives. Unlike
    /// a suspend the guest is still running afterwards, so each one is owed
    /// back to it as it goes
    /// (``VMLiveStateCapture/captureLiveState(_:session:wasRunning:saveFileURL:captureDisks:)``):
    /// the capture's detach resets the device, macOS assigns it back after a
    /// delay nothing bounds, and that arrival follows the attach to this VM.
    /// `record` that throws leaves nothing behind: unlisted files are files no
    /// surface can reach or remove, so the capture is undone.
    ///
    /// Admitted and committed before this returns, its end resolving
    /// `outcome`; `record` is how the caller learns the snapshot that landed.
    func launchTakeSnapshot(
        _ instance: VMInstance, mode: VMCaptureMode, snapshot: VMSnapshotCaptureRequest,
        resolving outcome: VMOutcome,
        record: @escaping @MainActor (borrowing VMEditPermit, VMSnapshot) throws -> Void
    ) throws {
        try instance.activity.launchCaptureSnapshot(mode, resolving: outcome) {
            [virtualizationService] context in
            let ending = try await virtualizationService.takeSnapshot(
                instance, context, snapshot: snapshot)
            switch ending {
            case .failed(let rest, let error):
                return .failed(rest, error)
            case .rest(let rest, let captured):
                do {
                    try record(context.operation.permit, captured)
                } catch {
                    await context.operation.bundle.removeSnapshotDirectory(captured.id)
                    return .failed(rest, error)
                }
                return .rest(rest, ())
            }
        }
    }

    /// Starts the revert of `instance` to `snapshot` as an operation no caller
    /// has to wait on, answering its outcome.
    ///
    /// Admitted and committed before this returns, so whatever asks next —
    /// a Start, a quit, the next power-off — finds the VM held by the revert,
    /// which resolves `outcome`. `landed` runs inside the operation, as its
    /// write, once the snapshot's files are in the bundle, including when the
    /// resume after them failed; a throw from it fails the revert.
    ///
    /// The VM's session is marked unsettled (``VMHostState/hasUnsettledSession``)
    /// before the first file is replaced, and recorded settled once every file
    /// has landed — so a revert cut short is owed again, and one that fails to
    /// mark replaces nothing.
    @discardableResult
    func startRevert(
        _ instance: VMInstance, to snapshot: VMSnapshot, resumesAfter: Bool,
        origin: VMRequestOrigin = .newWork, identity: VMIdentityOverride = .unavailable,
        resolving outcome: VMOutcome = VMOutcome(),
        commitConfiguration:
            @escaping @MainActor (borrowing VMEditPermit, VMSnapshotRestorePlan) throws -> Void,
        landed: @escaping @MainActor (borrowing VMEditPermit) throws -> Void
    ) throws -> VMOutcome {
        try instance.activity.launchRevert(
            to: snapshot, resumesAfter: resumesAfter, origin: origin, identity: identity,
            resolving: outcome
        ) {
            [virtualizationService] context in
            let ending = try await virtualizationService.revertToSnapshot(
                instance, context,
                commitConfiguration: { permit, plan in
                    try context.bringUp.operation.changingFiles()
                    try commitConfiguration(permit, plan)
                })
            let rest: VMOperationRest
            switch ending {
            case .rest(let landedAt, _):
                rest = landedAt
            case .failed(let failedAt, let error):
                // A resume that failed left the reverted files in place, so the
                // VM's state does descend from this snapshot. Any other failure
                // stopped short of every file landing.
                guard case VirtualizationError.revertResumeFailed = error else { return ending }
                rest = failedAt
            }
            do {
                try landed(context.bringUp.operation.permit)
                context.bringUp.operation.filesLanded()
            } catch {
                return .failed(rest, error)
            }
            return ending
        }
    }

    /// Takes one snapshot off the list with `unlist`, then moves its captured
    /// files to the Trash, inside one operation — so a delete cannot run while
    /// a revert is copying out of the same directory, and a delete refused as
    /// busy has unlisted nothing. An `unlist` that throws leaves the files in
    /// place.
    func discardSnapshot(
        _ instance: VMInstance, snapshotID: UUID,
        unlist: @MainActor (borrowing VMEditPermit) throws -> Void
    ) async throws {
        try await instance.activity.perform(.deletingSnapshot) { context in
            try unlist(context.permit)
            try await context.bundle.discardSnapshot(snapshotID)
            return .rest(.asStarted, ())
        }
    }

    // MARK: - macOS Installation

    /// The effective IPSW download destination for a persisted path: the path
    /// itself when it names a file directly inside `downloadsDirectory`,
    /// otherwise the destination `remoteURL` derives inside Downloads.
    ///
    /// Downloads is the only destination the app supports — the sandbox
    /// entitlement covers it, resume sidecar included, with no per-pick grant.
    ///
    /// The replacement is built from the remote URL through
    /// ``RestoreImageFilename`` rather than from the persisted path, because
    /// both the path and the URL come out of a `config.json` a user can edit:
    /// only a filename this app derived is safe to append to Downloads.
    func normalizedDownloadDestination(for persisted: URL, remoteURL: URL) -> URL {
        guard !isInsideDownloads(persisted) else { return persisted }
        return downloadsDirectory.appendingPathComponent(
            RestoreImageFilename.destination(for: remoteURL))
    }

    /// The destination a "Download Latest" install writes to, named by the URL
    /// the install just resolved.
    ///
    /// Any persisted path is only the wizard's preview of that answer: the
    /// newest build can move between wizard and Start, and only a name derived
    /// from the URL actually fetched keeps ``RestoreImageFilename``'s per-build
    /// identity honest for the file the bytes land in.
    func latestDownloadDestination(resolvedURL: URL) -> URL {
        downloadsDirectory.appendingPathComponent(RestoreImageFilename.destination(for: resolvedURL))
    }

    /// Whether `candidate` names a file sitting directly in the Downloads
    /// directory, which the directory itself does not.
    ///
    /// Symlink-resolved because the sandbox container's `Downloads` and the real
    /// `~/Downloads` are the same directory spelled two ways.
    private func isInsideDownloads(_ candidate: URL) -> Bool {
        let downloadsPath = Self.canonicalPath(downloadsDirectory)
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

    // MARK: - Guest Setup

    /// Starts the guest setup `instance`'s configuration still owes — a macOS
    /// install, or a Linux installer image download — as an operation that
    /// owns its task, answering its outcome.
    ///
    /// Admitted and committed before this returns, so a second request is
    /// refused as busy, and Cancel Setup (``VMActivity/cancel(_:)``) cancels
    /// the operation's own task. A cancel — or a failure that raced one —
    /// rests the VM at `.initialBoot` for a retry that resumes the download.
    ///
    /// `whenEnded` runs at the setup's ending commit — see
    /// ``VMActivity/launchBringUp(_:identity:whenEnded:_:)``.
    @discardableResult
    func launchGuestSetup(
        on instance: VMInstance, identity: VMIdentityOverride = .unavailable,
        whenEnded: VMActivity.WhenEnded? = nil
    ) throws -> VMOutcome {
        guard let setup = instance.configuration.pendingGuestSetup else {
            throw VMAdmissionRefusal(refusal: .invalidState)
        }
        let kind: GuestSetupKind =
            switch setup {
            case .macOSInstall: .macOSInstall
            case .linuxImageDownload: .linuxImageDownload
            }
        return try instance.activity.launchBringUp(
            .settingUp(kind), identity: identity, whenEnded: whenEnded
        ) {
            operation in
            do {
                switch setup {
                case .macOSInstall(let context):
                    try await self.installMacOS(on: instance, operation, context: context)
                case .linuxImageDownload(let context):
                    try await self.downloadLinuxImage(on: instance, operation, context: context)
                }
                // A cancel accepted while the pipeline was drawing to a close
                // still means the VM must not boot.
                try Task.checkCancellation()
            } catch {
                instance.setupState = nil
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                throw error
            }
            return .rest(.atRest(.stopped), ())
        }
    }

    private func installMacOS(
        on instance: VMInstance,
        _ operation: borrowing VMBringUpContext,
        context: MacOSInstallContext
    ) async throws {
        Self.logger.log(
            .debug,
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
                instance.setupState = .macOSInstall(hasDownloadStep: true)

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
                    guard let pinnedURL = context.remoteURL,
                        let persistedDestination = context.downloadDestinationURL
                    else {
                        throw IPSWError.noDownloadURL
                    }
                    remoteURL = pinnedURL
                    // A persisted destination outside Downloads (a hand-edited
                    // config.json) can never be written and has no picker to
                    // re-point it, so the invariant is enforced at use time.
                    downloadDestination = normalizedDownloadDestination(
                        for: persistedDestination, remoteURL: remoteURL)
                    if DownloadService.destinationKey(for: downloadDestination)
                        != DownloadService.destinationKey(for: persistedDestination)
                    {
                        Self.logger.log(
                            .notice,
                            "installMacOS: persisted download destination is outside Downloads; using the derived destination instead"
                        )
                    }
                } else {
                    remoteURL = try await ipswService.fetchLatestRestoreImage().url
                    downloadDestination = latestDownloadDestination(resolvedURL: remoteURL)
                    let persistedDestination = context.downloadDestinationURL
                    if persistedDestination.map(DownloadService.destinationKey(for:))
                        != DownloadService.destinationKey(for: downloadDestination)
                    {
                        Self.logger.log(
                            .notice,
                            "installMacOS: resolved latest image names the download '\(downloadDestination.lastPathComponent, privacy: .public)'"
                        )
                        // "Download & Replace" was confirmed against the
                        // wizard's destination, if it named one; a destination
                        // it did not name is a file the user never saw, so the
                        // intent lapses rather than retargets.
                        requestedFreshDownload = false
                        // A moved destination also means the fetch changed
                        // builds, so this VM can never resume the old path's
                        // partial download — discard it before this VM's only
                        // pointer to it moves.
                        if let persistedDestination {
                            discardSetupResumeData(
                                at: persistedDestination, leftBy: instance, permanently: false)
                        }
                        // Keep the persisted path on the file the download
                        // actually writes, so resume across relaunches and
                        // delete-time cleanup stay keyed to it — a step the
                        // install stops on, since a download no record
                        // points at can be neither resumed nor cleaned up.
                        try operation.operation.permit.updateConfiguration {
                            $0.installContext?.downloadDestinationPath =
                                downloadDestination.path(percentEncoded: false)
                            $0.installContext?.requestedFreshDownload = false
                        }.get()
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
                        Self.logger.log(
                            .error,
                            "installMacOS: refusing to honor requestedFreshDownload for non-IPSW destination '\(downloadDestination.path(percentEncoded: false), privacy: .public)'"
                        )
                        throw DownloadError.invalidDownloadDestination(
                            path: downloadDestination.path(percentEncoded: false)
                        )
                    }

                    Self.logger.log(
                        .notice,
                        "installMacOS: honoring requestedFreshDownload for '\(instance.name, privacy: .public)' — the existing IPSW + bundle are trashed before the download starts"
                    )
                    // Recorded before anything is trashed, or a retry would
                    // trash what this download fetched.
                    try operation.operation.permit.updateConfiguration {
                        $0.installContext?.requestedFreshDownload = false
                    }.get()
                }

                try await downloadService.download(
                    from: remoteURL,
                    to: downloadDestination,
                    discardsExistingDownload: requestedFreshDownload,
                    // Apple publishes no size for a restore image ahead of the
                    // transfer, so there is no ceiling to hold this one to.
                    expectedSizeBytes: nil
                ) { progress in
                    instance.setupState?.progress = .download(progress)
                }

                instance.setupState?.advance(progress: .fraction(0))
                ipswURL = downloadDestination

            case .localFile:
                guard let localURL = context.localIPSWURL else {
                    throw IPSWError.noDownloadURL
                }
                let reference = instance.configuration.externalFileReferences
                    .first { $0.kind == .localIPSW }
                let opened = reference.flatMap { ScopedAccess.open($0) }
                localIPSWScope = opened?.scope
                // Prefer the bookmark's resolved URL — it tracks the file if
                // it moved since the wizard pick.
                ipswURL = localIPSWScope?.url ?? localURL
                // The context survives relaunches until the install succeeds,
                // so its stored path and bookmark can both drift between
                // retries. The install reads the resolved URL above, so a
                // write that fails costs nothing here: it is reported, and
                // the next attempt resolves the bookmark again.
                if let reference, let healed = opened?.healedTo {
                    operation.operation.permit.updateConfiguration {
                        $0.healExternalReference(
                            reference, movedTo: healed.path, bookmark: healed.bookmark)
                    }
                }

                instance.setupState = .macOSInstall(hasDownloadStep: false)
            }

            let installedImage = try await installService.install(
                into: instance,
                operation,
                restoreImageURL: ipswURL
            ) { @MainActor progress in
                instance.setupState?.progress = .fraction(progress)
            }

            // Clear the persisted install intent so subsequent Starts take the
            // normal boot path, record the image this VM now carries, and
            // clear `setupState` so the progress UI tears down before the
            // caller chains an auto-boot. The account the VM was set up with
            // stays: the boot that delivers it has not run yet, and anything
            // interrupting the two must leave the next Start something to ask
            // about. An install whose completion does not land fails: the
            // context stays on disk, so the next Start installs again.
            try operation.operation.permit.updateConfiguration {
                $0.installContext = nil
                $0.installedImage = installedImage
            }.get()
            instance.setupState = nil
        } catch is CancellationError {
            Self.logger.log(.info, "macOS installation cancelled for '\(instance.name, privacy: .public)'")
            // Re-thrown as the cancel it is, which rests the VM at
            // .initialBoot rather than chaining a boot.
            throw CancellationError()
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            Self.logger.log(.info, "IPSW download cancelled for '\(instance.name, privacy: .public)'")
            // Normalize to CancellationError for consistent caller-side handling.
            throw CancellationError()
        } catch {
            let nsError = error as NSError
            Self.logger.log(
                .error,
                "Install failed for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public) [\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public); underlying: \(VirtualizationFailure.underlyingChainDescription(nsError), privacy: .public)]"
            )
            throw error
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
    func linuxDownloadDestination(filename: String) -> URL {
        downloadsDirectory.appendingPathComponent(filename)
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
    /// The digest the adopted file matched, or `nil` whenever the candidate
    /// cannot be shown to be the image — the ordinary download.
    private func adoptLocalImage(
        _ image: ResolvedLinuxImage, matching expected: ExpectedDigest, as destination: URL
    ) async throws -> InstallerImageDigest? {
        // A file already at the destination belongs to the download: it skips
        // over it and the verify step below holds it to this same digest. An
        // adoption is refused there in any case — asked before the hash rather
        // than after it, so a second VM built from one catalog entry does not
        // read gigabytes to reach a refusal. Read from the filesystem the rest
        // of this probe reads, not the trash seam.
        guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false))
        else { return nil }

        // Re-admitted at the point it is appended to a directory: this is the
        // one place a name the source chose reaches the filesystem.
        guard let candidateName = SafeFilename.sanitized(image.filename, requiring: "iso") else {
            return nil
        }
        let candidate = downloadsDirectory.appendingPathComponent(candidateName)
        // A source is free to publish a name already shaped like a
        // discriminated one; a file may not be linked onto itself.
        guard
            DownloadService.destinationKey(for: candidate)
                != DownloadService.destinationKey(for: destination)
        else { return nil }

        // The length the mirror states, checked with a stat before gigabytes
        // are read: a truncated or unrelated file under the same name costs
        // nothing to reject, so the hash below essentially only runs on a file
        // that will match.
        let values = try? candidate.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values?.isRegularFile == true, values?.isSymbolicLink == false,
            values?.fileSize.map(UInt64.init(clamping:)) == image.sizeBytes
        else { return nil }

        Self.logger.log(
            .notice,
            "downloadLinuxImage: hashing '\(candidateName, privacy: .public)', already in Downloads, against the digest published for it"
        )
        let actual: String
        do {
            actual = try await FileDigest.sha256(of: candidate)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.log(
                .warning,
                "downloadLinuxImage: could not hash '\(candidateName, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
        guard let digest = expected.match(actual, filename: image.filename) else {
            Self.logger.log(
                .notice,
                "downloadLinuxImage: '\(candidateName, privacy: .public)' hashes to \(actual, privacy: .public), not the published \(expected.sha256, privacy: .public) — downloading"
            )
            return nil
        }
        guard await downloadService.adoptExistingFile(at: candidate, as: destination) else {
            return nil
        }
        return digest
    }

    /// Hashes the installer image at `file` and records what it matched:
    /// `expected` when there is one, nothing when there is not.
    ///
    /// Throws ``DownloadError/checksumMismatch(filename:expected:actual:)``,
    /// trashing the file, when the bytes miss `expected`.
    private func digestInstallerImage(
        at file: URL, filename: String, against expected: ExpectedDigest?,
        progress: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws -> InstallerImageDigest {
        let actual = try await FileDigest.sha256(of: file, progressHandler: progress)
        guard let expected else { return .unchecked(filename: filename, sha256: actual) }
        guard let digest = expected.match(actual, filename: filename) else {
            Self.logger.log(
                .error,
                "downloadLinuxImage: '\(filename, privacy: .public)' hashes to \(actual, privacy: .public), not the expected \(expected.sha256, privacy: .public)"
            )
            discardUnverifiedImage(at: file)
            throw DownloadError.checksumMismatch(
                filename: filename, expected: expected, actual: actual)
        }
        return digest
    }

    /// Fetches the Linux installer image `context` names, hashes it — checked
    /// against the digest published or supplied for it, recorded unchecked when
    /// there is none — and attaches it as the VM's boot media.
    ///
    /// Every step is re-entrant: a cancelled or failed attempt leaves the
    /// context in place, so the next Start resolves again and resumes from
    /// whatever partial bytes are on disk.
    private func downloadLinuxImage(
        on instance: VMInstance,
        _ operation: borrowing VMBringUpContext,
        context: LinuxInstallContext
    ) async throws {
        Self.logger.log(
            .debug,
            "downloadLinuxImage: entering for '\(instance.name, privacy: .public)', image=\(context.imageDisplayName, privacy: .public)"
        )

        do {
            instance.setupState = .linuxImage(digestSource: context.source.digestSource)

            // Resolved on every attempt: a catalog entry because the mirror
            // renames its ISO in place (see `LinuxImageCatalogEntry`), a
            // pasted URL because the size it answers with is the ceiling
            // this transfer is held to.
            let (image, expected) = try await context.source.resolve(
                using: linuxImageResolveService)

            // `image.destinationFilename`, never the name the source gave
            // the ISO: Downloads holds everything the user has ever
            // fetched, and a file already sitting under the source's name
            // is one the download would adopt in place of fetching, or
            // trash for failing a digest that was never its own.
            let downloadDestination = linuxDownloadDestination(filename: image.destinationFilename)

            if let persisted = context.downloadDestinationURL,
                DownloadService.destinationKey(for: persisted)
                    != DownloadService.destinationKey(for: downloadDestination)
            {
                Self.logger.log(
                    .notice,
                    "downloadLinuxImage: the resolution moved to '\(image.filename, privacy: .public)', downloading to '\(downloadDestination.lastPathComponent, privacy: .public)'"
                )
                // The partial at the abandoned path belongs to an image
                // this download is no longer fetching, so discard it before
                // this VM's only pointer to it moves.
                discardSetupResumeData(at: persisted, leftBy: instance, permanently: false)
            }
            // Keep the persisted path on the file the download writes, so
            // resume across relaunches and delete-time cleanup stay keyed
            // to it; the download does not start unless it lands.
            try operation.operation.permit.updateConfiguration {
                $0.linuxInstallContext?.downloadDestinationPath =
                    downloadDestination.path(percentEncoded: false)
            }.get()

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
            let digest: InstallerImageDigest
            if let expected,
                let adopted = try await adoptLocalImage(
                    image, matching: expected, as: downloadDestination)
            {
                // The digest decided the adoption, so Verify has nothing
                // left to check and the step is drawn finished.
                instance.setupState?.advance(progress: .fraction(1))
                digest = adopted
            } else {
                // Never replaces: the destination is named for this URL, so
                // a file already there is what a prior attempt at this same
                // image fetched, and adopting it is right — the step below
                // hashes it exactly as it would a fresh download.
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
                // destination: Verify holds them to the digest, and a pasted
                // URL with none behind it still has its checksum recorded.
                instance.setupState?.advance(progress: .fraction(0))
                digest = try await digestInstallerImage(
                    at: downloadDestination, filename: image.filename, against: expected
                ) { fraction in
                    instance.setupState?.progress = .fraction(fraction)
                }
            }

            try attachInstallerImage(
                at: downloadDestination, named: image.filename,
                from: InstalledImage(linuxSource: context.source, digest: digest),
                operation.operation.permit)
            instance.setupState = nil
        } catch is CancellationError {
            Self.logger.log(
                .info,
                "Linux image download cancelled for '\(instance.name, privacy: .public)'")
            // Re-thrown as the cancel it is, which rests the VM at
            // .initialBoot rather than chaining a boot.
            throw CancellationError()
        } catch let error as NSError
            where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
        {
            Self.logger.log(
                .info,
                "Linux image download cancelled for '\(instance.name, privacy: .public)'")
            // Normalize to CancellationError for consistent caller-side handling.
            throw CancellationError()
        } catch {
            let nsError = error as NSError
            Self.logger.log(
                .error,
                "Linux image download failed for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public) [\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)]"
            )
            throw error
        }
    }

    /// Discards the `.kernovadownload` bundle at `destination` that
    /// `instance`'s setup no longer needs — unless another VM's pending setup
    /// still downloads into it (``VMInstance/anotherSetupDownloads(into:)``).
    ///
    /// Two VMs installing the same build share one destination and one bundle,
    /// so the bundle is either the other VM's live transfer or the bytes it
    /// resumes from; the last VM targeting the destination discards it.
    /// `permanently` bypasses the Trash.
    func discardSetupResumeData(
        at destination: URL, leftBy instance: VMInstance, permanently: Bool
    ) {
        guard !instance.anotherSetupDownloads(into: destination) else {
            Self.logger.log(
                .notice,
                "Kept the in-progress download '\(destination.lastPathComponent, privacy: .public)' that '\(instance.name, privacy: .public)' left — another VM's setup downloads into it"
            )
            return
        }
        downloadService.discardResumeData(at: destination, permanently: permanently)
    }

    /// Trashes an image whose digest did not match, and any resume bundle left
    /// beside it.
    ///
    /// Left in place, the file would satisfy the download's skip-existing fast
    /// path on every retry and the VM could never reach a good copy.
    private func discardUnverifiedImage(at destination: URL) {
        do {
            try fileSystem.trashItem(at: destination)
            Self.logger.log(
                .notice,
                "Trashed '\(destination.lastPathComponent, privacy: .public)' — it did not match its expected checksum"
            )
        } catch {
            Self.logger.log(
                .warning,
                "Failed to trash the unverified image at '\(destination.path(percentEncoded: false), privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
        downloadService.discardResumeData(at: destination, permanently: false)
    }

    /// Attaches the fetched installer image ahead of the VM's main disk,
    /// records `installedImage` as what the VM was set up from, and clears the
    /// pending download intent — throwing when that write does not land, so the
    /// setup fails and nothing boots.
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
        at destination: URL, named filename: String, from installedImage: InstalledImage,
        _ permit: borrowing VMEditPermit
    ) throws {
        let instance = permit.instance
        let installer = StorageDisk(
            path: destination.path(percentEncoded: false),
            readOnly: true,
            label: (filename as NSString).deletingPathExtension,
            bookmark: SecurityScopedBookmark.make(for: destination)
        )
        let layout = VMBundleLayout(bundleURL: instance.bundleURL)
        try permit.updateConfiguration { config in
            // Position [0] is what EFI boots first, which is the whole reason
            // the installer is on the list at all.
            config.setStorageDisks([installer] + config.effectiveStorageDisks(layout: layout))
            config.linuxInstallContext = nil
            config.installedImage = installedImage
        }.get()
        Self.logger.log(
            .notice,
            "Attached installer image '\(destination.lastPathComponent, privacy: .public)' to '\(instance.name, privacy: .public)'"
        )
    }

    // MARK: - Removable Media Management

    /// Attaches a USB mass storage device to a running VM and records it on
    /// `instance`, making it visible through `instance.liveRemovableMedia`.
    ///
    /// `desiredUUID` overrides the framework-generated
    /// `VZUSBDeviceConfiguration.uuid` so the runtime device matches the caller's
    /// persisted identity, which save-state restore matches on. `resolvedURL`,
    /// when supplied, is what actually gets attached, while the *tracked* identity
    /// stays `diskImagePath`.
    ///
    /// `sessionID` is the session the caller's pass is acting for; a pass that
    /// has been overtaken throws `RemovableMediaDeviceError.noVirtualMachine` without
    /// reaching the framework, so its remaining attaches cannot drive a
    /// successor's controller from the predecessor's diff.
    func attachRemovableMedia(
        diskImagePath: String,
        readOnly: Bool,
        desiredUUID: UUID? = nil,
        resolvedURL: URL? = nil,
        to instance: VMInstance,
        for sessionID: UUID
    ) async throws -> RemovableMediaDeviceInfo {
        guard instance.liveSessionID == sessionID else { throw RemovableMediaDeviceError.noVirtualMachine }
        let info = try await removableMediaDeviceService.attach(
            diskImagePath: diskImagePath,
            attaching: resolvedURL,
            readOnly: readOnly,
            desiredUUID: desiredUUID,
            to: instance
        )
        instance.recordAttachedMedia(info, for: sessionID)
        return info
    }

    /// Detaches a device the session `sessionID` names is holding, and clears
    /// its tracking entry — dropping to `RemovableMediaDeviceError.noVirtualMachine`
    /// before the framework call for the reason
    /// ``attachRemovableMedia(diskImagePath:readOnly:desiredUUID:resolvedURL:to:for:)``
    /// does.
    func detachRemovableMedia(
        _ deviceInfo: RemovableMediaDeviceInfo,
        from instance: VMInstance,
        for sessionID: UUID
    ) async throws {
        guard instance.liveSessionID == sessionID else { throw RemovableMediaDeviceError.noVirtualMachine }
        try await removableMediaDeviceService.detach(deviceInfo: deviceInfo, from: instance)
        instance.forgetAttachedMedia(deviceID: deviceInfo.id, for: sessionID)
    }

    // MARK: - USB Accessories

    /// Passes the accessory `registryID` names through to the guest of the
    /// session `sessionID` names, inside an operation holding the VM whose
    /// admission reserved the accessory for it.
    ///
    /// The operation is what makes the save paths' "no passthrough device on
    /// the controller when `saveMachineState` runs" post-condition hold by
    /// construction rather than by timing: a save or a snapshot cannot start
    /// while this is in flight, and this cannot start while one of those is.
    ///
    /// `whileHeld` runs once the accessory is the guest's, as a write of the
    /// operation still holding the VM.
    @discardableResult
    func attachUSBAccessory(
        _ registryID: UInt64,
        to instance: VMInstance,
        for sessionID: UUID,
        whileHeld: ((borrowing VMEditPermit, AttachedUSBAccessory) -> Void)? = nil
    ) async throws -> AttachedUSBAccessory {
        try await instance.activity.attachUSBAccessory(registryID) { context in
            let attached = try await passThrough(
                context, to: instance, for: sessionID, whileHeld: whileHeld)
            return .rest(.asStarted, attached)
        }
    }

    /// ``attachUSBAccessory(_:to:for:whileHeld:)`` as an operation no caller
    /// has to wait on, resolving `outcome` — admitted and committed before
    /// this returns, and throwing the refusal otherwise.
    func launchUSBAccessoryAttach(
        _ registryID: UInt64,
        to instance: VMInstance,
        for sessionID: UUID,
        resolving outcome: VMOutcome,
        whileHeld: ((borrowing VMEditPermit, AttachedUSBAccessory) -> Void)? = nil
    ) throws {
        try instance.activity.launchUSBAccessoryAttach(registryID, resolving: outcome) {
            context in
            _ = try await self.passThrough(
                context, to: instance, for: sessionID, whileHeld: whileHeld)
            return .rest(.asStarted, ())
        }
    }

    /// The body of every attach: passes the accessory `context` reserved
    /// through to the guest of the session `sessionID` names, and records it
    /// as that guest's.
    private func passThrough(
        _ context: borrowing VMUSBAttachContext,
        to instance: VMInstance,
        for sessionID: UUID,
        whileHeld: ((borrowing VMEditPermit, AttachedUSBAccessory) -> Void)?
    ) async throws -> AttachedUSBAccessory {
        guard let usbAccessoryService else { throw USBAccessoryError.noUSBController }
        guard context.operation.sessionID == sessionID else {
            throw USBAccessoryError.noVirtualMachine
        }
        let attached = try await usbAccessoryService.attach(context.reservation)
        // VZ captured the device while this was suspended, and a session
        // that went away under the call released the reservation with it —
        // leaving the device captured by a VM nothing holds. Hand it back.
        guard context.reservation.hold(attached) else {
            try? await usbAccessoryService.detach(deviceID: attached.deviceID, from: instance)
            Self.logger.log(
                .notice,
                "Released USB accessory \(attached.accessory.displayName, privacy: .public): '\(instance.name, privacy: .public)' lost its session under the attach"
            )
            throw USBAccessoryError.noVirtualMachine
        }
        whileHeld?(context.operation.permit, attached)
        return attached
    }

    /// Detaches the passthrough device `deviceID` names and releases it from
    /// the VM, inside an operation holding the VM.
    ///
    /// A device VZ no longer holds is a success, not a failure: a surprise
    /// unplug or a save's own detach sweep may have got there first, and the
    /// outcome the caller asked for already holds. The release happens either
    /// way.
    ///
    /// `whileHeld` runs once the device is off, as a write of the operation
    /// still holding the VM.
    func detachUSBAccessory(
        deviceID: UUID,
        from instance: VMInstance,
        for sessionID: UUID,
        whileHeld: ((borrowing VMEditPermit) -> Void)? = nil
    ) async throws {
        try await instance.activity.perform(.detachingUSB(deviceID: deviceID)) { context in
            guard let usbAccessoryService else { throw USBAccessoryError.noUSBController }
            guard context.sessionID == sessionID else { throw USBAccessoryError.noVirtualMachine }
            do {
                try await usbAccessoryService.detach(deviceID: deviceID, from: instance)
            } catch USBAccessoryError.deviceNotFound {
                Self.logger.log(
                    .notice,
                    "USB accessory \(deviceID.uuidString, privacy: .public) was already off '\(instance.name, privacy: .public)'"
                )
            }
            context.releaseAccessory(deviceID: deviceID)
            whileHeld?(context.permit)
            return .rest(.asStarted, ())
        }
    }
}
