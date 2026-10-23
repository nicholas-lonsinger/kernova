import Foundation
import KernovaKit
import KernovaLogging

/// How bundles on disk become library membership: the library read, the
/// directory-watched reconcile, and the arrival pipeline that publishes a
/// create, clone or import. Every path ends in ``VMLibrary/adopt(_:)``.
extension VMLibrary {
    /// Fills the library from disk, then starts reconciling it with the VMs
    /// directory as ``VMDirectoryWatcher`` triggers.
    ///
    /// Called once, from `applicationWillFinishLaunching`. Not part of `init`:
    /// everything the initializer does runs before `NSApplication.run()`, so a
    /// library read there sits between process start and the first window. The
    /// watcher starts only after the read applies — its callback re-reads every
    /// bundle on the main actor, which must not race the initial load.
    ///
    /// Answers what ``loadVMs()`` answers.
    @discardableResult
    func startLibrary() async -> Set<UUID> {
        storageService.reclaimStagedBundles()
        await reclaimInterruptedWork()
        let marked = await loadVMs()
        startDirectoryWatcher()
        return marked
    }

    /// Catches the named networks, the smart groups, and every VM at rest, up
    /// with what another
    /// copy of Kernova holds and wrote (``VMActivity/refreshFromBundle()``) —
    /// every VM, or only those `ids` names.
    ///
    /// Run on events, never on a timer: an `flock` raises no file-system event
    /// to watch, so a mark stays what the last of these found.
    ///
    /// With `reportingUnreadable` false, a file the read finds unreadable is
    /// recorded for the next report to name, and nothing comes on screen now.
    func refreshFromOtherCopies(only ids: Set<UUID>? = nil, reportingUnreadable: Bool = true) {
        networks.reload()
        organization.reload()
        recordUnreadableLibraryFiles()
        for instance in instances where ids?.contains(instance.id) ?? true {
            refreshFromOtherCopies(of: instance)
        }
        if reportingUnreadable { reportNewlyUnreadable() }
    }

    /// Records the named networks' and the organization's files as their last
    /// read found them.
    private func recordUnreadableLibraryFiles() {
        if let file = networks.file {
            recordUnreadable([networks.state.unreadable].compactMap { $0 }, under: file.url)
        }
        if let file = organization.file {
            recordUnreadable([organization.state.unreadable].compactMap { $0 }, under: file.url)
        }
    }

    /// Catches `instance` alone up with what another copy of Kernova holds and
    /// wrote, recording a file it finds unreadable for the next report to name
    /// and reading no library file.
    func refreshFromOtherCopies(of instance: VMInstance) {
        // A bundle this copy holds is not re-read, and records nothing until
        // the hold ends (``recordUnreadableFiles(of:)``).
        guard let unreadable = instance.activity.refreshFromBundle() else { return }
        recordUnreadable(unreadable, under: instance.bundleURL)
    }

    /// Records every file of `instance`'s bundle a read refuses, read for
    /// that alone (``VMBundle/rereadUnreadableFiles()``) — the list its
    /// re-read from the bundle (``VMActivity/refreshFromBundle()``)
    /// publishes too, so a bundle is reported from one source whichever read
    /// takes it.
    func recordUnreadableFiles(of instance: VMInstance) {
        recordUnreadable(instance.bundle.rereadUnreadableFiles(), under: instance.bundleURL)
    }

    /// Removes what an interrupted revert or resume left — a revert's staging
    /// directory and a spent suspend slot — in any listed bundle another copy
    /// of Kernova does not hold.
    ///
    /// Finished before the load, so no VM of this run exists yet and no revert
    /// or resume of its own can be working there. A bundle that arrives later,
    /// or that another copy held, keeps what it holds until a later launch
    /// reclaims it — or, sooner, its next revert stages over the staging
    /// directory, or its next resume from a saved state spends over the spent
    /// slot.
    private func reclaimInterruptedWork() async {
        let storage = storageService
        let bundleFactory = bundleFactory
        await Task.detached(priority: .userInitiated) { [logger] in
            let bundles: [URL]
            do {
                bundles = try storage.listVMBundles()
            } catch {
                // The load that follows lists the directory again and reports
                // it to the user.
                logger.log(
                    .warning,
                    "Could not list the VM bundles to reclaim revert staging and spent suspend slots: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
            bundleFactory.reclaimInterruptedWork(
                in: bundles.map { VMBundleFiles(url: $0, access: storage.bundleFiles) })
        }.value
    }

    // MARK: - Reading Bundles

    /// What a bundle is read through, gathered so the reads can run off the
    /// main actor.
    ///
    /// A bundle enters the library as a VM whole or not at all: one whose
    /// configuration, host state or snapshot manifest cannot be read becomes
    /// an ``UnreadableVM`` instead, so no write can replace a file whose
    /// contents were never known. Pairings are the exception
    /// ``VMBundleFiles/read()`` states.
    struct BundleReader: Sendable {
        let storage: any VMStorageProviding

        func files(at bundleURL: URL) -> VMBundleFiles {
            VMBundleFiles(url: bundleURL, access: storage.bundleFiles)
        }

        /// Reads the bundle and the phase it rests in.
        func bundle(at bundleURL: URL) throws(UnreadableConfigFile) -> ScannedBundle {
            let read = try read(at: bundleURL)
            return ScannedBundle(
                read: read,
                phase: .atRest(
                    for: read.configuration, layout: VMBundleLayout(bundleURL: bundleURL)))
        }

        /// Reads the bundle's state files, and nothing else in it.
        ///
        /// Blocks on the filesystem, so it runs where the other bundle reads
        /// do.
        func read(at bundleURL: URL) throws(UnreadableConfigFile) -> VMBundleRead {
            try files(at: bundleURL).read()
        }
    }

    var bundleReader: BundleReader {
        BundleReader(storage: storageService)
    }

    /// The order bundles are adopted in, so which of two bundles holding one
    /// identifier wins is the same at every launch and reconcile.
    nonisolated static func bundleNameOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }

    // MARK: - Load

    /// The whole library as read from disk in one pass.
    struct LibraryScan: Sendable {
        var bundles: [ScannedBundle] = []
        /// The bundles that could not be read, each with the file that kept
        /// it out.
        var unreadable: [UnreadableBundle] = []
        /// The bundles another copy of Kernova held the run lock of when the
        /// scan asked, just before reading them.
        var heldElsewhere: Set<URL> = []
    }

    /// Reads every bundle under the VMs directory, in ``bundleNameOrder(_:_:)``,
    /// asking each first whether another copy of Kernova holds it — the order
    /// ``VMActivity/refreshFromBundle()`` asks and reads in.
    ///
    /// Nonisolated so the disk work can run off the main actor; it touches no
    /// library state, reports failures through the returned scan, and logs
    /// each unreadable bundle to `logger`.
    nonisolated static func scanLibrary(
        using reader: BundleReader, logger: KernovaLogger
    ) throws -> LibraryScan {
        var scan = LibraryScan()
        for bundleURL in try reader.storage.listVMBundles().sorted(by: bundleNameOrder) {
            if reader.files(at: bundleURL).isRunLockedElsewhere() { scan.heldElsewhere.insert(bundleURL) }
            do {
                scan.bundles.append(try reader.bundle(at: bundleURL))
            } catch {
                logUnreadable(bundleURL, error, to: logger)
                scan.unreadable.append(UnreadableBundle(url: bundleURL, file: error))
            }
        }
        return scan
    }

    /// Logs to `logger` what kept the bundle at `url` out, coding path and all.
    nonisolated private static func logUnreadable(
        _ url: URL, _ file: UnreadableConfigFile, to logger: KernovaLogger
    ) {
        logger.log(
            .error,
            "Failed to load VM from \(url.lastPathComponent, privacy: .public): \(file.fileName, privacy: .public) \(String(describing: file.problems), privacy: .public)"
        )
    }

    /// Adopts every bundle on disk into the library.
    ///
    /// The read runs off the main actor — a library of any size is bound by
    /// per-bundle file reads, and blocking the main actor for them stalls
    /// whatever window is already on screen. What joined the library while it
    /// ran stays: adoption of a bundle a VM is already built from changes
    /// nothing.
    ///
    /// The read is the one this copy takes of every bundle at once: each VM it
    /// adopts is marked held when another copy held it, and the named networks'
    /// and organization's files are reported as the library last read them.
    ///
    /// Answers the VMs it adopted whose host state it read marked to start
    /// automatically (``VMHostState/startsAutomaticallyOnLaunch``).
    @discardableResult
    func loadVMs() async -> Set<UUID> {
        unreadableReports = UnreadableFileReports()
        reportedDuplicateBundles.removeAll()
        let reader = bundleReader
        let logger = self.logger
        // Whatever the read returns, it is over: a listing that failed answers
        // "no VMs" too, and UI must not go on waiting for a load that finished.
        defer { hasLoadedLibrary = true }
        do {
            let scan = try await Task.detached(priority: .userInitiated) {
                try Self.scanLibrary(using: reader, logger: logger)
            }.value
            return apply(scan)
        } catch {
            logger.log(.error, "Failed to load VM library: \(error.localizedDescription, privacy: .public)")
            presentError(error, about: .library)
            return []
        }
    }

    /// Turns a scan into the live library: membership, order, and selection —
    /// answering the VMs it adopted that the scan read marked to start
    /// automatically — and settles each session it finds ended unsettled
    /// (``VMActivity/settleUnsettledSessionAtLaunch()``).
    private func apply(_ scan: LibraryScan) -> Set<UUID> {
        var marked: Set<UUID> = []
        var unsettled: [VMInstance] = []
        for scanned in scan.bundles {
            guard case .adopted(let instance) = adopt(scanned) else { continue }
            instance.activity.recordOtherCopyHold(heldElsewhere: scan.heldElsewhere.contains(scanned.url))
            if scanned.read.hostState.startsAutomaticallyOnLaunch { marked.insert(instance.id) }
            if scanned.read.hostState.hasUnsettledSession { unsettled.append(instance) }
        }
        // A session a copy of Kernova died under was never settled, and taking
        // the lock is what shows no copy runs it now.
        for instance in unsettled { instance.activity.settleUnsettledSessionAtLaunch() }
        admitUnreadable(scan.unreadable)
        for bundle in scan.unreadable {
            recordUnreadable([bundle.file], under: bundle.url)
        }
        recordUnreadableLibraryFiles()
        macAddresses.logDuplicateMACAddressHolders()
        reportNewlyUnreadable()

        if let savedOrder = preferences.vmOrder {
            customOrder = savedOrder
            logger.log(.debug, "Loaded custom VM order: \(self.customOrder.count, privacy: .public) UUID(s)")
        } else {
            logger.log(.debug, "No custom VM order found — using default createdAt sort")
        }
        sortEntries()
        customOrder = entries.map(\.id)

        restoreSelection()
        logger.log(.notice, "Loaded \(self.instances.count, privacy: .public) VMs")
        return marked
    }

    // MARK: - Directory Watcher

    private func startDirectoryWatcher() {
        let vmsDir: URL
        do {
            vmsDir = try storageService.vmsDirectory
        } catch {
            logger.log(
                .warning,
                "Could not resolve VMs directory for file system watcher: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        let watcher = VMDirectoryWatcher(appActivation: appActivation) { [weak self] in
            self?.reconcileWithDisk()
        }
        watcher.start(directory: vmsDir)
        directoryWatcher = watcher
    }

    // MARK: - Reconcile

    /// Brings the library in step with the bundles listed on disk: adopts the
    /// ones it does not know, re-binds a VM whose bundle moved, and evicts a VM
    /// at rest whose bundle is no longer listed.
    ///
    /// A bundle still being written sits under the hidden staging directory,
    /// which the listing never admits, so nothing an arrival is writing can be
    /// adopted early.
    func reconcileWithDisk() {
        logger.log(.debug, "reconcileWithDisk: starting")
        do {
            let diskBundles = try storageService.listVMBundles().sorted(by: Self.bundleNameOrder)
            let reader = bundleReader

            // The bundles that become unreadable rows: those this pass could
            // not read that no VM in the library is built from.
            var unreadable: [UnreadableBundle] = []
            // The VMs this pass found in a listed bundle it could read, or
            // holds.
            var confirmedIDs: Set<UUID> = []
            func noteUnreadable(_ bundleURL: URL, _ file: UnreadableConfigFile) {
                Self.logUnreadable(bundleURL, file, to: logger)
                // A VM already built from the bundle keeps its row, for the
                // reason the eviction below is keyed on the listing, and its
                // bundle is reported as ``refreshFromOtherCopies(only:)``
                // reports it — every file read, where this pass read
                // `config.json` alone.
                if let instance = instances.first(where: { isSameBundle($0.bundleURL, bundleURL) }) {
                    recordUnreadableFiles(of: instance)
                    return
                }
                recordUnreadable([file], under: bundleURL)
                unreadable.append(UnreadableBundle(url: bundleURL, file: file))
            }
            var didChange = false
            for bundleURL in diskBundles {
                // A bundle this copy holds is a VM already, and no other copy
                // writes it, so it is not read.
                if let held = instances.first(where: {
                    $0.activity.holdsRunLock && isSameBundle($0.bundleURL, bundleURL)
                }) {
                    confirmedIDs.insert(held.id)
                    continue
                }
                let id: UUID
                do {
                    id = try reader.files(at: bundleURL).readConfiguration().id
                } catch {
                    noteUnreadable(bundleURL, error)
                    continue
                }
                if let known = entries.first(where: { $0.id == id })?.vm,
                    VMBundleIdentity.spelling(known.bundleURL) == VMBundleIdentity.spelling(bundleURL)
                {
                    confirmedIDs.insert(id)
                    continue
                }
                do {
                    switch adopt(try reader.bundle(at: bundleURL)) {
                    case .adopted(let instance):
                        logger.log(
                            .info,
                            "Discovered VM '\(instance.name, privacy: .public)' on disk — added to library")
                        confirmedIDs.insert(instance.id)
                        didChange = true
                    case .rebound(let instance):
                        confirmedIDs.insert(instance.id)
                        didChange = true
                    case .alreadyAdopted(let instance):
                        confirmedIDs.insert(instance.id)
                    case .publishing, .duplicate:
                        break
                    }
                } catch {
                    noteUnreadable(bundleURL, error)
                }
            }
            if admitUnreadable(unreadable) { didChange = true }
            let currentDiskNames = Set(diskBundles.map { $0.deletingPathExtension().lastPathComponent })

            // Keyed on the listing rather than on what was read, so a bundle
            // whose configuration is momentarily unreadable keeps its VM.
            let listed = Set(diskBundles.compactMap(storageService.bundleIdentity(at:)))
            for instance in instances {
                if let identity = storageService.bundleIdentity(at: instance.bundleURL),
                    listed.contains(identity)
                {
                    continue
                }
                // Only a VM at rest is evicted: one an operation holds keeps
                // its row until the operation ends, and the next pass finds it.
                guard (try? instance.activity.remove()) != nil else { continue }
                evict(instance)
                logger.log(
                    .info,
                    "VM '\(instance.name, privacy: .public)' no longer on disk — removed from library")
                didChange = true
            }

            if didChange {
                sortEntries()
                persistOrder()
                macAddresses.logDuplicateMACAddressHolders()
            }

            // Forget what was reported of bundles no longer on disk, so a new
            // bundle at the same place is not silently suppressed.
            unreadableReports.forgetAll(
                outside: diskBundles + [networks.file?.url, organization.file?.url].compactMap { $0 })
            reportedDuplicateBundles.formIntersection(currentDiskNames)

            // Bounded to the VMs this pass read: a bundle it could not see says
            // nothing about what is inside. The watcher behind this pass sees
            // only the VMs directory, so a file changed inside a bundle — a
            // suspend slot removed in the Finder — is caught up here, at the
            // next pass for any reason.
            refreshFromOtherCopies(only: confirmedIDs)

            logger.log(
                .debug,
                "reconcileWithDisk: complete — \(self.instances.count, privacy: .public) VM(s) in library")
        } catch {
            logger.log(
                .error, "Directory reconciliation failed: \(error.localizedDescription, privacy: .public)")
            presentError(error, about: .library)
        }
    }

    // MARK: - Arrivals

    /// Registers the row for a create, clone or import and starts writing its
    /// bundle, answering the arrival whose ``VMArrival/settled`` carries the
    /// outcome.
    ///
    /// Synchronous up to the registration, so a batch of arrivals each sees the
    /// ones before it. `write` receives `staged` and must write *only* there:
    /// the tree becomes a bundle at one instant — the publication rename — so
    /// an abnormal exit at any point before it leaves nothing to adopt, and the
    /// launch reclaim discards it.
    ///
    /// `whenAdopted` answers the follow-ups the VM the arrival becomes owes,
    /// which its adoption step follows — so the first request decided against
    /// the new VM is theirs.
    func beginArrival(
        kind: VMArrival.Kind, configuration: VMConfiguration, destination: URL,
        staged: VMStagedBundle, source: VMArrival.Source?, starting: VMArrival.Starting = VMArrival.Starting(),
        write: @escaping (VMStagedBundle) async throws -> Void,
        whenAdopted: (@MainActor (VMInstance) -> [VMFollowUp])? = nil
    ) -> VMArrival {
        let arrival = VMArrival(
            id: configuration.id, kind: kind, configuration: configuration,
            destinationURL: destination, staged: staged, source: source, starting: starting
        ) { [weak self] arrival in
            guard let self else { throw CancellationError() }
            return try await self.settle(arrival, writtenBy: write, whenAdopted: whenAdopted)
        }
        register(arrival)
        return arrival
    }

    /// Runs `arrival` to its outcome and removes its row, handing a failure to
    /// ``onArrivalFailed`` first.
    private func settle(
        _ arrival: VMArrival, writtenBy write: (VMStagedBundle) async throws -> Void,
        whenAdopted: (@MainActor (VMInstance) -> [VMFollowUp])?
    ) async throws -> VMInstance {
        do {
            let instance = try await publish(
                arrival, writtenBy: write, whenAdopted: whenAdopted)
            removeArrival(arrival)
            return instance
        } catch {
            onArrivalFailed?(arrival, error)
            removeArrival(arrival)
            throw error
        }
    }

    /// Writes, validates, publishes and adopts `arrival`'s bundle.
    ///
    /// ``VMArrival/beginPublishing()`` is the last point a cancel stops the
    /// write; up to it, every exit discards the staged tree outright — it is
    /// app-internal, and its source still exists. The VM is built from what
    /// disk holds after the rename, not what the staged tree held before it.
    /// A cancel taken during the rename is decided in the same main-actor step
    /// as the adoption: the published bundle goes to the Trash before the
    /// arrival settles, so nothing that follows the arrival ever receives its
    /// VM.
    ///
    /// Every outcome a cancel produced is thrown as `CancellationError`. The
    /// VM the arrival became follows what `whenAdopted` answers in the step
    /// that adopts it.
    private func publish(
        _ arrival: VMArrival, writtenBy write: (VMStagedBundle) async throws -> Void,
        whenAdopted: (@MainActor (VMInstance) -> [VMFollowUp])?
    ) async throws -> VMInstance {
        let storage = storageService
        let reader = bundleReader
        let staged = arrival.staged.url
        do {
            try await write(arrival.staged)
            try Task.checkCancellation()
            // Read before publication, so a written tree holding a file the
            // library cannot read — an import's, say — never becomes a bundle.
            _ = try await Task.detached { try reader.read(at: staged) }.value
            guard arrival.beginPublishing() else { throw CancellationError() }
        } catch {
            await discardStagedTree(at: staged)
            throw arrival.isCancelling ? CancellationError() : error
        }
        let destination = arrival.destinationURL
        do {
            try await Task.detached { try storage.publishBundle(from: staged, to: destination) }
                .value
        } catch {
            await discardStagedTree(at: staged)
            throw arrival.isCancelling ? CancellationError() : error
        }
        logger.log(
            .notice,
            "\(arrival.kind.displayNoun, privacy: .public) of '\(arrival.name, privacy: .public)' published at \(destination.lastPathComponent, privacy: .public)"
        )
        let scanned: Result<ScannedBundle, any Error>
        do {
            scanned = .success(try await Task.detached { try reader.bundle(at: destination) }.value)
        } catch {
            scanned = .failure(error)
        }
        guard arrival.finishPublishing() else { try await withdraw(arrival, read: scanned) }
        switch adopt(try scanned.get(), publishing: arrival) {
        case .adopted(let instance), .alreadyAdopted(let instance), .rebound(let instance):
            macAddresses.logDuplicateMACAddressHolders()
            for followUp in whenAdopted?(instance) ?? [] { instance.activity.follow(followUp) }
            return instance
        case .publishing, .duplicate:
            throw ArrivalError.identifierInUse(name: arrival.name)
        }
    }

    /// Moves the bundle an arrival published after its cancel to the Trash,
    /// throwing the cancel.
    ///
    /// A bundle the Trash turns down stays where it was published, so it is
    /// adopted as the VM it now is and the refusal is thrown in place of the
    /// cancel.
    private func withdraw(
        _ arrival: VMArrival, read scanned: Result<ScannedBundle, any Error>
    ) async throws -> Never {
        let storage = storageService
        let destination = arrival.destinationURL
        do {
            try await Task.detached { try storage.deleteVMBundle(at: destination) }.value
        } catch {
            logger.log(
                .error,
                "Could not move the cancelled \(arrival.kind.displayNoun.lowercased(), privacy: .public) of '\(arrival.name, privacy: .public)' to the Trash: \(error.localizedDescription, privacy: .public)"
            )
            if case .success(let bundle) = scanned {
                _ = adopt(bundle, publishing: arrival)
            }
            throw ArrivalError.withdrawalFailed(
                name: arrival.name, reason: error.localizedDescription)
        }
        logger.log(
            .notice,
            "\(arrival.kind.displayNoun, privacy: .public) of '\(arrival.name, privacy: .public)' cancelled during its publication — moved to the Trash"
        )
        throw CancellationError()
    }

    /// Why a published arrival became no VM, or a cancelled one did.
    enum ArrivalError: LocalizedError {
        /// Another bundle took the arrival's identifier while it was written.
        case identifierInUse(name: String)
        /// A cancel taken during the rename could not move the published
        /// bundle to the Trash, so it stays in the library.
        case withdrawalFailed(name: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .identifierInUse(let name):
                "Another virtual machine with the identifier of \u{201C}\(name)\u{201D} is already in the library."
            case .withdrawalFailed(let name, let reason):
                "\u{201C}\(name)\u{201D} was already in the library when the cancel took effect, and it couldn\u{2019}t be moved to the Trash: \(reason)"
            }
        }
    }

    /// Removes a staged tree off the main actor, logging a removal that fails —
    /// the next launch's reclaim retries it, and the listing never admits it.
    private func discardStagedTree(at url: URL) async {
        let storage = storageService
        do {
            try await Task.detached { try storage.discardStagedBundle(at: url) }.value
        } catch {
            logger.log(
                .warning,
                "Could not discard the staged bundle at \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// A collision-free destination bundle URL under `vmsDir` for a bundle named like `sourceURL`.
    ///
    /// Taken names are the union of on-disk `.kernova` bundles in `vmsDir` AND
    /// the destinations of every row in the library there: an arrival's copy
    /// hasn't published yet, so a disk listing alone can't see it. The
    /// destination does not exist yet, so it has no file identity: names are
    /// matched as ``VMBundleIdentity/nameKey(_:)`` folds them.
    func reserveDestination(for sourceURL: URL, in vmsDir: URL) -> URL {
        let onDiskStems =
            (try? FileManager.default.contentsOfDirectory(
                at: vmsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?
            .filter { VMStorageService.isBundleURL($0) }
            .map { $0.deletingPathExtension().lastPathComponent } ?? []
        let vmsDirKey = VMBundleIdentity.nameKey(vmsDir)
        let inFlightStems = entries.compactMap { entry -> String? in
            let url =
                switch entry {
                case .vm(let instance): instance.bundleURL
                case .arriving(let arrival): arrival.destinationURL
                case .unreadable(let bundle): bundle.bundleURL
                }
            guard VMBundleIdentity.nameKey(url.deletingLastPathComponent()) == vmsDirKey else {
                return nil
            }
            return url.deletingPathExtension().lastPathComponent
        }
        let name = UniqueName.firstAvailable(
            prefix: sourceURL.deletingPathExtension().lastPathComponent,
            existing: onDiskStems + inFlightStems,
            caseInsensitive: true)
        return vmsDir.appendingPathComponent(
            "\(name).\(VMBundleFormat.fileExtension)", isDirectory: true)
    }

    /// Stops every arrival still short of publication and discards the tree it
    /// has written so far, for a quit that cannot wait for the copies to settle.
    ///
    /// An arrival already publishing is left alone: its tree is complete on
    /// either side of the rename, so the next launch reclaims it from the
    /// staging directory or adopts it from the VMs directory. Best effort:
    /// `FileManager.copyItem` isn't interruptible, so a copy already in flight
    /// can keep writing into the staged path after the discard, and the next
    /// launch's reclaim removes whatever it left.
    ///
    /// The discard is synchronous — the process ends immediately after, so a
    /// detached removal would never run.
    func abandonArrivalsForTermination() {
        for arrival in arrivals where arrival.stage == .writing || arrival.stage == .cancelling {
            _ = arrival.requestCancel()
            logger.log(
                .notice,
                "Terminating: abandoning \(arrival.kind.displayNoun, privacy: .public) of '\(arrival.name, privacy: .public)'"
            )
            do {
                try storageService.discardStagedBundle(at: arrival.staged.url)
            } catch {
                logger.log(
                    .warning,
                    "Failed to discard the staged bundle for '\(arrival.name, privacy: .public)' during termination: \(error.localizedDescription, privacy: .public)"
                )
            }
            removeArrival(arrival)
        }
    }
}
