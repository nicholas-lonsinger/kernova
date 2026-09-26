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
    let linuxImageResolveService: any LinuxImageResolving
    let downloadService: any Downloading

    /// Passes host USB accessories through to a guest, or `nil` when this build
    /// cannot — see ``USBAccessorySupport/makeService(entitlements:)``.
    let usbAccessoryService: (any USBAccessoryProviding)?

    /// How long a capture waits for the accessories it ejected to be assigned
    /// again before putting back whichever of them arrived.
    ///
    /// One bound over the whole put-back rather than one per accessory: the
    /// waits run together. It covers the event arriving late — a detach's
    /// re-assignment lands in well under a second — and does not outlast an
    /// accessory that is not coming back, because the capture operation holds
    /// the VM for the whole wait and a start arriving behind it is refused as
    /// busy.
    private let usbAccessoryReturnTimeout: Duration

    /// Trashes an image that failed verification.
    private let fileSystem: any FileSystemOperating

    /// The directory downloads must land in — the one location the sandbox's
    /// downloads entitlement covers.
    ///
    /// `nil` disables normalization.
    private let downloadsDirectory: URL?

    init(
        virtualizationService: any VirtualizationProviding,
        installService: any MacOSInstallProviding,
        ipswService: any IPSWProviding,
        removableMediaDeviceService: any RemovableMediaAttaching = RemovableMediaDeviceService(),
        // No default that builds one: ``USBAccessorySupport/makeService(entitlements:)``
        // is called in exactly one place, the composition root, and a
        // collaborator that mints its own would register a second
        // process-wide AccessoryAccess listener. Absent is the capability
        // being absent, which every surface already reads as such.
        usbAccessoryService: (any USBAccessoryProviding)? = nil,
        usbAccessoryReturnTimeout: Duration = .seconds(5),
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
        self.removableMediaDeviceService = removableMediaDeviceService
        self.usbAccessoryService = usbAccessoryService
        self.usbAccessoryReturnTimeout = usbAccessoryReturnTimeout
        self.linuxImageResolveService = linuxImageResolveService
        self.downloadService = downloadService
        self.fileSystem = fileSystem
        self.downloadsDirectory = downloadsDirectory
    }

    // MARK: - Lifecycle

    /// Brings `instance` up by the guest start `kind` names.
    func start(
        _ instance: VMInstance, _ kind: VMGuestStartKind,
        provisioning: GuestProvisioningCredentials? = nil
    ) async throws -> GuestStartRoute {
        try await instance.activity.startGuest(kind) { context in
            try await virtualizationService.start(instance, context, provisioning: provisioning)
        }
    }

    /// Requests a graceful stop — a session action, which takes no admission
    /// of its own, so an operation that tolerates it keeps holding the VM.
    func requestStop(_ instance: VMInstance) async throws {
        try await instance.activity.requestStop {
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
    func discardSavedState(_ instance: VMInstance) throws {
        try instance.activity.performNow(.discardingSavedState) {
            (context: borrowing VMOperationContext) -> VMOperationEnding<Void> in
            context.bundle.removeSaveFile()
            guard !context.bundle.hasSaveFile else {
                return .failed(.asStarted, VirtualizationError.savedStateNotDiscarded)
            }
            #log(
                Self.logger, .notice,
                "Discarded saved state for VM '\(instance.name, privacy: .public)'")
            return .rest(.atRest(.stopped), ())
        }
    }

    func pause(_ instance: VMInstance) async throws {
        try await instance.activity.perform(.pausing) { context in
            try await virtualizationService.pause(instance, context)
        }
    }

    /// Resumes a live-paused VM from memory.
    func resume(_ instance: VMInstance) async throws {
        try await instance.activity.perform(.resuming) { context in
            try await virtualizationService.resume(instance, context)
        }
    }

    /// Suspends the VM to disk.
    ///
    /// The accessories the write ejects stay off, on both outcomes: the guest
    /// is going away, and a suspend that fails takes the session down with it,
    /// so there is no guest left to put anything back on.
    func save(_ instance: VMInstance) async throws {
        try await instance.activity.perform(.saving) { context in
            try await virtualizationService.save(instance, context)
        }
    }

    // MARK: - Snapshots

    /// Captures `snapshot` in `mode` and lists it with `record`, inside one
    /// capture operation.
    ///
    /// A warm capture takes every passthrough accessory off before it writes
    /// the guest's state, because a saved state carrying one cannot be
    /// restored. Unlike a suspend the guest is still running afterwards, so
    /// they go back on — on the path where the capture threw part-way as well,
    /// since it ejected the same hardware up to wherever it stopped. `record`
    /// that throws leaves nothing behind: unlisted files are files no surface
    /// can reach or remove, so the capture is undone.
    func takeSnapshot(
        _ instance: VMInstance, mode: VMSnapshotCaptureMode, snapshot: VMSnapshotCaptureRequest,
        record: @MainActor (VMSnapshot) throws -> Void
    ) async throws -> VMSnapshot {
        try await instance.activity.captureSnapshot(mode) { context in
            // Read before the capture, since the capture is what clears them.
            let held = instance.liveUSBAccessories
            let sessionID = context.operation.sessionID
            let ending: VMOperationEnding<VMSnapshot>
            do {
                ending = try await virtualizationService.takeSnapshot(
                    instance, context, snapshot: snapshot)
            } catch {
                if let sessionID {
                    await reattachUSBAccessories(ejectedFrom: held, on: instance, for: sessionID)
                }
                throw error
            }
            if let sessionID {
                await reattachUSBAccessories(ejectedFrom: held, on: instance, for: sessionID)
            }
            guard case .rest(let rest, let captured) = ending else { return ending }
            do {
                try record(captured)
            } catch {
                await context.operation.bundle.removeSnapshotDirectory(captured.id)
                return .failed(rest, error)
            }
            return ending
        }
    }

    /// Puts back the accessories a capture took off `instance`.
    ///
    /// `held` is what the guest was holding before the capture ran; what it
    /// still holds is what the capture never reached, so the difference is what
    /// was ejected — on the path where the capture succeeded and on the one
    /// where its detach sweep threw part-way through, having already ejected
    /// and forgotten the items ahead of the failure.
    ///
    /// Each one has to be found again before it can be attached: the capture's
    /// detach reset the device, so the `registryID` it went off under names
    /// nothing, and macOS assigns the same stick back under a new one. Matching
    /// is on the durable identity and the wait is event-driven — see
    /// ``USBAccessoryProviding/accessory(matching:appearingWithin:)``.
    ///
    /// Guarded on the session at every step: a guest that went away under the
    /// capture has no controller to attach to. Failures are logged and
    /// swallowed — the snapshot the user asked for is already written, and an
    /// accessory that will not go back on leaves the guest exactly where a
    /// surprise unplug would.
    private func reattachUSBAccessories(
        ejectedFrom held: [AttachedUSBAccessory], on instance: VMInstance, for sessionID: UUID
    ) async {
        guard let usbAccessoryService, !held.isEmpty,
            instance.liveSessionID == sessionID
        else { return }
        let stillHeld = Set(instance.liveUSBAccessories.map(\.deviceID))
        let ejected = held.filter { !stillHeld.contains($0.deviceID) }
        guard !ejected.isEmpty else { return }

        let returned = await returningAccessories(ejected, on: instance, for: sessionID)
        for item in ejected {
            guard let accessory = returned[item.deviceID] else { continue }
            guard instance.liveSessionID == sessionID else { return }
            do {
                let reattached = try await usbAccessoryService.attach(
                    accessory.registryID, to: instance)
                guard instance.liveSessionID == sessionID else {
                    try? await usbAccessoryService.detach(
                        deviceID: reattached.deviceID, from: instance)
                    return
                }
                instance.recordAttachedAccessory(reattached, for: sessionID)
            } catch {
                #log(
                    Self.logger, .warning,
                    "Could not put USB accessory \(item.accessory.displayName, privacy: .public) back on '\(instance.name, privacy: .public)' after the capture: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// One accessory being waited for, and the attachment it went off under.
    private struct PendingUSBReturn {
        let item: AttachedUSBAccessory
        let wait: Task<USBAccessoryInfo?, Never>
    }

    /// The accessories `ejected` names, as macOS has assigned them back, keyed
    /// by the attachment each went off under.
    ///
    /// Every wait is started before any is awaited, so the deadline they carry
    /// bounds the put-back once rather than once per accessory: the
    /// re-assignments are independent and arrive when macOS is ready, while a
    /// sequential wait would hold the capture operation for the timeout
    /// multiplied by however many accessories the guest had, with the last
    /// one's budget starting only once the first had given up.
    ///
    /// The guest going away cancels them, because nothing can be put back on a
    /// session that is gone and the deadline would otherwise keep the capture
    /// holding the VM past a stop the user is waiting on.
    private func returningAccessories(
        _ ejected: [AttachedUSBAccessory], on instance: VMInstance, for sessionID: UUID
    ) async -> [UUID: USBAccessoryInfo] {
        let timeout = usbAccessoryReturnTimeout
        let pending = ejected.compactMap { item -> PendingUSBReturn? in
            guard let identity = item.accessory.identity else {
                #log(
                    Self.logger, .warning,
                    "Cannot put USB accessory \(item.accessory.displayName, privacy: .public) back after the capture: nothing durable identifies it"
                )
                return nil
            }
            return PendingUSBReturn(
                item: item,
                wait: Task { @MainActor [weak self] in
                    guard let service = self?.usbAccessoryService else { return nil }
                    return await service.accessory(matching: identity, appearingWithin: timeout)
                })
        }
        guard !pending.isEmpty else { return [:] }

        let sessionWatch = observeRecurring(
            track: { _ = instance.liveSessionID },
            apply: {
                guard instance.liveSessionID != sessionID else { return }
                for entry in pending { entry.wait.cancel() }
            })
        defer { sessionWatch.cancel() }

        var found: [UUID: USBAccessoryInfo] = [:]
        for entry in pending {
            let returned = await entry.wait.value
            guard instance.liveSessionID == sessionID else {
                #log(
                    Self.logger, .notice,
                    "'\(instance.name, privacy: .public)' went away before the USB accessories the capture took off came back, so they stay with the host"
                )
                return [:]
            }
            guard let returned else {
                #log(
                    Self.logger, .warning,
                    "USB accessory \(entry.item.accessory.displayName, privacy: .public) was not assigned back to Kernova after the capture, so it stayed off the guest"
                )
                continue
            }
            found[entry.item.deviceID] = returned
        }
        return found
    }

    /// Starts the revert of `instance` to `snapshot` as an operation no caller
    /// has to wait on, answering its outcome.
    ///
    /// Admitted and committed before this returns, so whatever asks next —
    /// a Start, a quit, the next power-off — finds the VM held by the revert.
    /// `landed` runs inside the operation once the snapshot's files are in the
    /// bundle, including when the resume after them failed; a throw from it
    /// fails the revert.
    @discardableResult
    func startRevert(
        _ instance: VMInstance, to snapshot: VMSnapshot, resumesAfter: Bool,
        commitConfiguration: @escaping @MainActor (VMSnapshotRestorePlan) throws -> Void,
        landed: @escaping @MainActor () throws -> Void
    ) throws -> VMOutcome {
        try instance.activity.launchRevert(to: snapshot, resumesAfter: resumesAfter) {
            [virtualizationService] context in
            let ending = try await virtualizationService.revertToSnapshot(
                instance, context, commitConfiguration: commitConfiguration)
            switch ending {
            case .rest(let rest, _):
                do { try landed() } catch { return .failed(rest, error) }
            case .failed(let rest, let error):
                // A resume that failed left the reverted files in place, so the
                // VM's state does descend from this snapshot. Any other failure
                // left nothing behind.
                guard case VirtualizationError.revertResumeFailed = error else { break }
                do { try landed() } catch { return .failed(rest, error) }
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
        _ instance: VMInstance, snapshotID: UUID, unlist: @MainActor () throws -> Void
    ) async throws {
        try await instance.activity.perform(.deletingSnapshot) { context in
            try unlist()
            try await context.bundle.discardSnapshot(snapshotID)
            return .rest(.asStarted, ())
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
    /// ``VMActivity/launchBringUp(_:whenEnded:_:)``.
    @discardableResult
    func launchGuestSetup(
        on instance: VMInstance,
        whenEnded: (@MainActor (Result<Void, any Error>) -> Void)? = nil
    ) throws -> VMOutcome {
        guard let setup = instance.configuration.pendingGuestSetup else {
            throw VMAdmissionRefusal(refusal: .invalidState)
        }
        let kind: GuestSetupKind =
            switch setup {
            case .macOSInstall: .macOSInstall
            case .linuxImageDownload: .linuxImageDownload
            }
        return try instance.activity.launchBringUp(.settingUp(kind), whenEnded: whenEnded) {
            operation in
            do {
                switch setup {
                case .macOSInstall(let context):
                    try await self.installMacOS(on: instance, operation, context: context)
                case .linuxImageDownload(let context):
                    try await self.downloadLinuxImage(on: instance, context: context)
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
        #log(
            Self.logger, .debug,
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
                        #log(
                            Self.logger, .notice,
                            "installMacOS: persisted download destination is outside Downloads; using the derived destination instead"
                        )
                    }
                } else {
                    remoteURL = try await ipswService.fetchLatestRestoreImage().url
                    downloadDestination = latestDownloadDestination(
                        persisted: persistedDestination, resolvedURL: remoteURL)
                    if downloadDestination != persistedDestination {
                        #log(
                            Self.logger, .notice,
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
                        // delete-time cleanup stay keyed to it — a step the
                        // install stops on, since a download no record
                        // points at can be neither resumed nor cleaned up.
                        try instance.performConfigurationMutation {
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
                        #log(
                            Self.logger, .error,
                            "installMacOS: refusing to honor requestedFreshDownload for non-IPSW destination '\(downloadDestination.path(percentEncoded: false), privacy: .public)'"
                        )
                        throw DownloadError.invalidDownloadDestination(
                            path: downloadDestination.path(percentEncoded: false)
                        )
                    }

                    #log(
                        Self.logger, .notice,
                        "installMacOS: honoring requestedFreshDownload for '\(instance.name, privacy: .public)' — the existing IPSW + bundle are trashed before the download starts"
                    )
                    // Recorded before anything is trashed, or a retry would
                    // trash what this download fetched.
                    try instance.performConfigurationMutation {
                        $0.installContext?.requestedFreshDownload = false
                    }.get()
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
                    instance.performConfigurationMutation {
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
            try instance.performConfigurationMutation {
                $0.installContext = nil
                $0.installedImage = installedImage
            }.get()
            instance.setupState = nil
        } catch is CancellationError {
            #log(Self.logger, .info, "macOS installation cancelled for '\(instance.name, privacy: .public)'")
            // Re-thrown as the cancel it is, which rests the VM at
            // .initialBoot rather than chaining a boot.
            throw CancellationError()
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            #log(Self.logger, .info, "IPSW download cancelled for '\(instance.name, privacy: .public)'")
            // Normalize to CancellationError for consistent caller-side handling.
            throw CancellationError()
        } catch {
            let nsError = error as NSError
            #log(
                Self.logger, .error,
                "Install failed for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public) [\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public); underlying: \(VirtualizationService.underlyingChainDescription(nsError), privacy: .public)]"
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

        #log(
            Self.logger, .notice,
            "downloadLinuxImage: hashing '\(candidateName, privacy: .public)', already in Downloads, against the digest published for it"
        )
        let digest: String
        do {
            digest = try await FileDigest.sha256(of: candidate) { _ in }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            #log(
                Self.logger, .warning,
                "downloadLinuxImage: could not hash '\(candidateName, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        guard digest == expected else {
            #log(
                Self.logger, .notice,
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
    private func downloadLinuxImage(
        on instance: VMInstance,
        context: LinuxInstallContext
    ) async throws {
        #log(
            Self.logger, .debug,
            "downloadLinuxImage: entering for '\(instance.name, privacy: .public)', image=\(context.imageDisplayName, privacy: .public)"
        )

        do {
            instance.setupState = .linuxImage(hasVerifyStep: context.hasVerifyStep)

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
                #log(
                    Self.logger, .notice,
                    "downloadLinuxImage: the resolution moved to '\(image.filename, privacy: .public)', downloading to '\(downloadDestination.lastPathComponent, privacy: .public)'"
                )
                // The partial at the abandoned path belongs to an image
                // this download is no longer fetching, so discard it before
                // the only pointer to it moves.
                downloadService.discardResumeData(at: persisted, permanently: false)
            }
            // Keep the persisted path on the file the download writes, so
            // resume across relaunches and delete-time cleanup stay keyed
            // to it; the download does not start unless it lands.
            try instance.performConfigurationMutation {
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
                        #log(
                            Self.logger, .error,
                            "downloadLinuxImage: '\(image.filename, privacy: .public)' hashes to \(digest, privacy: .public), not the expected \(expected, privacy: .public)"
                        )
                        discardUnverifiedImage(at: downloadDestination)
                        throw DownloadError.checksumMismatch(
                            filename: image.filename, expected: expected, actual: digest)
                    }
                }
            }

            try attachInstallerImage(
                at: downloadDestination, named: image.filename,
                from: InstalledImage(linuxSource: context.source), to: instance)
            instance.setupState = nil
        } catch is CancellationError {
            #log(
                Self.logger, .info,
                "Linux image download cancelled for '\(instance.name, privacy: .public)'")
            // Re-thrown as the cancel it is, which rests the VM at
            // .initialBoot rather than chaining a boot.
            throw CancellationError()
        } catch let error as NSError
            where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
        {
            #log(
                Self.logger, .info,
                "Linux image download cancelled for '\(instance.name, privacy: .public)'")
            // Normalize to CancellationError for consistent caller-side handling.
            throw CancellationError()
        } catch {
            let nsError = error as NSError
            #log(
                Self.logger, .error,
                "Linux image download failed for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public) [\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)]"
            )
            throw error
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
            #log(
                Self.logger, .notice,
                "Trashed '\(destination.lastPathComponent, privacy: .public)' — it did not match its expected checksum"
            )
        } catch {
            #log(
                Self.logger, .warning,
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
        at destination: URL, named filename: String, from installedImage: InstalledImage?,
        to instance: VMInstance
    ) throws {
        let installer = StorageDisk(
            path: destination.path(percentEncoded: false),
            readOnly: true,
            label: (filename as NSString).deletingPathExtension,
            bookmark: SecurityScopedBookmark.make(for: destination)
        )
        let layout = VMBundleLayout(bundleURL: instance.bundleURL)
        try instance.performConfigurationMutation { config in
            // Position [0] is what EFI boots first, which is the whole reason
            // the installer is on the list at all.
            config.setStorageDisks([installer] + config.effectiveStorageDisks(layout: layout))
            config.linuxInstallContext = nil
            config.installedImage = installedImage
        }.get()
        #log(
            Self.logger, .notice,
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
            diskImagePath: resolvedURL?.path(percentEncoded: false) ?? diskImagePath,
            readOnly: readOnly,
            desiredUUID: desiredUUID,
            to: instance
        )
        let tracked = RemovableMediaDeviceInfo(
            id: info.id, path: diskImagePath, readOnly: info.readOnly,
            attachedAt: info.attachedAt)
        instance.recordAttachedMedia(tracked, for: sessionID)
        return tracked
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
    /// session `sessionID` names, and records the attachment, inside an
    /// operation holding the VM.
    ///
    /// The operation is what makes the save paths' "no passthrough device on
    /// the controller when `saveMachineState` runs" post-condition hold by
    /// construction rather than by timing: a save or a snapshot cannot start
    /// while this is in flight, and this cannot start while one of those is.
    @discardableResult
    func attachUSBAccessory(
        _ registryID: UInt64,
        to instance: VMInstance,
        for sessionID: UUID
    ) async throws -> AttachedUSBAccessory {
        try await instance.activity.perform(.attachingUSB(registryID: registryID)) { context in
            guard let usbAccessoryService else { throw USBAccessoryError.noUSBController }
            guard context.sessionID == sessionID else { throw USBAccessoryError.noVirtualMachine }
            let attached = try await usbAccessoryService.attach(registryID, to: instance)
            // VZ captured the device while this was suspended, so a session that
            // went away under the call would leave it captured by a VM nothing
            // holds. Hand it back rather than record an attachment against a
            // session that is gone.
            guard context.sessionID == sessionID else {
                try? await usbAccessoryService.detach(deviceID: attached.deviceID, from: instance)
                #log(
                    Self.logger, .notice,
                    "Released USB accessory \(attached.accessory.displayName, privacy: .public): '\(instance.name, privacy: .public)' lost its session under the attach"
                )
                throw USBAccessoryError.noVirtualMachine
            }
            instance.recordAttachedAccessory(attached, for: sessionID)
            return .rest(.asStarted, attached)
        }
    }

    /// Detaches the passthrough device `deviceID` names and clears its tracking
    /// entry, inside an operation holding the VM.
    ///
    /// A device VZ no longer holds is a success, not a failure: a surprise
    /// unplug or a save's own detach sweep may have got there first, and the
    /// outcome the caller asked for already holds. The tracking entry goes
    /// either way.
    func detachUSBAccessory(
        deviceID: UUID,
        from instance: VMInstance,
        for sessionID: UUID
    ) async throws {
        try await instance.activity.perform(.detachingUSB(deviceID: deviceID)) { context in
            guard let usbAccessoryService else { throw USBAccessoryError.noUSBController }
            guard context.sessionID == sessionID else { throw USBAccessoryError.noVirtualMachine }
            do {
                try await usbAccessoryService.detach(deviceID: deviceID, from: instance)
            } catch USBAccessoryError.deviceNotFound {
                #log(
                    Self.logger, .notice,
                    "USB accessory \(deviceID.uuidString, privacy: .public) was already off '\(instance.name, privacy: .public)'"
                )
            }
            instance.forgetAttachedAccessory(deviceID: deviceID, for: sessionID)
            return .rest(.asStarted, ())
        }
    }
}
