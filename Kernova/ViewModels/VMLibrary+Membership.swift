import Foundation
import KernovaKit
import KernovaLogging

/// How bundles on disk become library membership: the library read, the
/// directory-watched reconcile, and the arrival pipeline that publishes a
/// create, clone or import. Every path ends in ``VMLibrary/adopt(_:)``.
extension VMLibrary {
    /// Fills the library from disk, then starts watching the VMs directory for
    /// changes made outside the app.
    ///
    /// Called once, from `applicationWillFinishLaunching`. Not part of `init`:
    /// everything the initializer does runs before `NSApplication.run()`, so a
    /// library read there sits between process start and the first window. The
    /// watcher starts only after the read applies — its callback re-reads every
    /// bundle on the main actor, which must not race the initial load.
    ///
    /// Launch is also where an interrupted run's staged bundles are reclaimed.
    /// Nothing waits on those removals: a staged name is minted per write, so one
    /// still in flight can never name a path this run is about to use.
    func startLibrary() async {
        storageService.reclaimStagedBundles()
        await reclaimRestoreStaging()
        await loadVMs()
        startDirectoryWatcher()
    }

    /// Removes the restore staging directory an interrupted revert left in any
    /// listed bundle.
    ///
    /// Finished before the load, so no VM of this run exists yet and no revert
    /// of its own can be staging there. A bundle that arrives later keeps what
    /// it holds until its next revert, whose staging discards it first.
    private func reclaimRestoreStaging() async {
        let storage = storageService
        let bundleFactory = bundleFactory
        await Task.detached(priority: .userInitiated) {
            let bundles: [URL]
            do {
                bundles = try storage.listVMBundles()
            } catch {
                // The load that follows lists the directory again and reports
                // it to the user.
                #log(
                    Self.logger, .warning,
                    "Could not list the VM bundles to reclaim revert staging: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
            bundleFactory.reclaimRestoreStaging(in: bundles)
        }.value
    }

    // MARK: - Initial Phase

    /// Phase to assign to a VM when it's first read from disk.
    ///
    /// A surviving install context — either guest's — is the canonical signal
    /// that the VM has never completed its initial boot, so it outranks
    /// `.suspended`/`.stopped`.
    nonisolated static func initialPhase(for config: VMConfiguration, layout: VMBundleLayout)
        -> VMLifecyclePhase
    {
        if config.pendingGuestSetup != nil {
            return .initialBoot
        }
        return layout.hasSaveFile ? .suspended : .stopped
    }

    // MARK: - Reading Bundles

    /// What a bundle is read through, gathered so the reads can run off the
    /// main actor.
    ///
    /// A bundle enters the library whole or not at all: one whose
    /// configuration, host state or snapshot manifest cannot be read stays
    /// out, so no write can replace a file whose contents were never known.
    /// Pairings are the exception ``VMBundleFiles/read()`` states.
    struct BundleReader: Sendable {
        let storage: any VMStorageProviding

        func files(at bundleURL: URL) -> VMBundleFiles {
            VMBundleFiles(url: bundleURL, access: storage.bundleFiles)
        }

        /// Reads the bundle and the phase it rests in.
        func bundle(at bundleURL: URL) throws -> ScannedBundle {
            let read = try read(at: bundleURL)
            return ScannedBundle(
                read: read,
                phase: VMLibrary.initialPhase(
                    for: read.configuration, layout: VMBundleLayout(bundleURL: bundleURL)))
        }

        /// Reads the bundle's state files, and nothing else in it.
        ///
        /// Blocks on the filesystem, so it runs where the other bundle reads
        /// do.
        func read(at bundleURL: URL) throws -> VMBundleRead {
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
        /// Bundle names that could not be read.
        var failedBundleNames: [String] = []
    }

    /// Reads every bundle under the VMs directory, in ``bundleNameOrder(_:_:)``.
    ///
    /// Nonisolated so the disk work can run off the main actor; it touches no
    /// library state and reports failures through the returned scan.
    nonisolated static func scanLibrary(using reader: BundleReader) throws -> LibraryScan {
        var scan = LibraryScan()
        for bundleURL in try reader.storage.listVMBundles().sorted(by: bundleNameOrder) {
            do {
                scan.bundles.append(try reader.bundle(at: bundleURL))
            } catch {
                #log(
                    logger, .error,
                    "Failed to load VM from \(bundleURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                scan.failedBundleNames.append(bundleURL.deletingPathExtension().lastPathComponent)
            }
        }
        return scan
    }

    /// Adopts every bundle on disk into the library.
    ///
    /// The read runs off the main actor — a library of any size is bound by
    /// per-bundle file reads, and blocking the main actor for them stalls
    /// whatever window is already on screen. What joined the library while it
    /// ran stays: adoption of a bundle a VM is already built from changes
    /// nothing.
    func loadVMs() async {
        reportedFailedBundles.removeAll()
        reportedDuplicateBundles.removeAll()
        let reader = bundleReader
        // Whatever the read returns, it is over: a listing that failed answers
        // "no VMs" too, and UI must not go on waiting for a load that finished.
        defer { hasLoadedLibrary = true }
        do {
            let scan = try await Task.detached(priority: .userInitiated) {
                try Self.scanLibrary(using: reader)
            }.value
            apply(scan)
        } catch {
            #log(Self.logger, .error, "Failed to load VM library: \(error.localizedDescription, privacy: .public)")
            presentError(error)
        }
    }

    /// Turns a scan into the live library: membership, order, and selection.
    private func apply(_ scan: LibraryScan) {
        for scanned in scan.bundles {
            _ = adopt(scanned)
        }
        macAddresses.logDuplicateMACAddressHolders()

        if !scan.failedBundleNames.isEmpty {
            reportedFailedBundles.formUnion(scan.failedBundleNames)
            presentError(LoadError.bundleLoadFailed(names: scan.failedBundleNames))
        }

        if let savedOrder = preferences.vmOrder {
            customOrder = savedOrder
            #log(Self.logger, .debug, "Loaded custom VM order: \(self.customOrder.count, privacy: .public) UUID(s)")
        } else {
            #log(Self.logger, .debug, "No custom VM order found — using default createdAt sort")
        }
        sortEntries()
        customOrder = entries.map(\.id)

        if selectedID == nil || !entries.contains(where: { $0.id == selectedID }) {
            if let savedID = preferences.lastSelectedVMID,
                entries.contains(where: { $0.id == savedID })
            {
                selectedID = savedID
                #log(Self.logger, .debug, "Restored last-selected VM from UserDefaults: \(savedID.uuidString)")
            } else {
                selectedID = entries.first?.id
            }
        }
        #log(Self.logger, .notice, "Loaded \(self.instances.count, privacy: .public) VMs")
    }

    // MARK: - Directory Watcher

    private func startDirectoryWatcher() {
        let vmsDir: URL
        do {
            vmsDir = try storageService.vmsDirectory
        } catch {
            #log(
                Self.logger, .warning,
                "Could not resolve VMs directory for file system watcher: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        let watcher = VMDirectoryWatcher { [weak self] in
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
        #log(Self.logger, .debug, "reconcileWithDisk: starting")
        do {
            let diskBundles = try storageService.listVMBundles().sorted(by: Self.bundleNameOrder)
            let reader = bundleReader

            var failedBundles: [String] = []
            // The VMs this pass found in a listed bundle it could read.
            var confirmedIDs: Set<UUID> = []
            var didChange = false
            for bundleURL in diskBundles {
                let bundleName = bundleURL.deletingPathExtension().lastPathComponent
                let id: UUID
                do {
                    id = try reader.files(at: bundleURL).readConfiguration().id
                } catch {
                    #log(
                        Self.logger, .error,
                        "Failed to load config from \(bundleURL.lastPathComponent, privacy: .public) during reconciliation: \(error.localizedDescription, privacy: .public)"
                    )
                    failedBundles.append(bundleName)
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
                        #log(
                            Self.logger, .info,
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
                    #log(
                        Self.logger, .error,
                        "Failed to load VM from \(bundleURL.lastPathComponent, privacy: .public) during reconciliation: \(error.localizedDescription, privacy: .public)"
                    )
                    failedBundles.append(bundleName)
                }
            }
            let currentDiskNames = Set(diskBundles.map { $0.deletingPathExtension().lastPathComponent })
            reportedFailedBundles.subtract(currentDiskNames.subtracting(failedBundles))

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
                #log(
                    Self.logger, .info,
                    "VM '\(instance.name, privacy: .public)' no longer on disk — removed from library")
                didChange = true
            }

            if didChange {
                sortEntries()
                persistOrder()
                macAddresses.logDuplicateMACAddressHolders()
            }

            let newFailures = failedBundles.filter { !reportedFailedBundles.contains($0) }
            let suppressedCount = failedBundles.count - newFailures.count
            if suppressedCount > 0 {
                #log(
                    Self.logger, .debug,
                    "reconcileWithDisk: suppressed \(suppressedCount, privacy: .public) already-reported bundle failure(s)"
                )
            }
            if !newFailures.isEmpty {
                reportedFailedBundles.formUnion(newFailures)
                presentError(LoadError.bundleLoadFailed(names: newFailures))
            }

            // Prune names of bundles no longer on disk so a new bundle with the same name
            // is not silently suppressed.
            reportedFailedBundles.formIntersection(currentDiskNames)
            reportedDuplicateBundles.formIntersection(currentDiskNames)

            normalizeEmptiedSuspensions(inBundles: confirmedIDs)

            #log(
                Self.logger, .debug,
                "reconcileWithDisk: complete — \(self.instances.count, privacy: .public) VM(s) in library")
        } catch {
            #log(
                Self.logger, .error, "Directory reconciliation failed: \(error.localizedDescription, privacy: .public)")
            presentError(error)
        }
    }

    /// Rests any VM naming a suspend slot its bundle no longer holds.
    ///
    /// ``VMLifecyclePhase/suspended`` names a session on disk, so a slot removed
    /// out of band — in the Finder, by another tool — leaves a phase describing
    /// something that is not there: the row still reads Suspended while every
    /// predicate that asks the bundle already offers Start and an editable
    /// configuration.
    ///
    /// Re-derived whenever the library reconciles, and no sooner: the watcher
    /// behind that pass observes the VMs directory, where a bundle is added,
    /// removed or renamed, so a file deleted *inside* a bundle wakes nothing.
    /// The phase catches up at the next reconciliation for any reason, and at
    /// the next launch.
    ///
    /// `bundlesOnDisk` bounds it to the VMs this pass actually read: a bundle
    /// the scan could not see says nothing about the slot inside it.
    private func normalizeEmptiedSuspensions(inBundles bundlesOnDisk: Set<UUID>) {
        for instance in instances
        where bundlesOnDisk.contains(instance.id) && instance.phase == .suspended
            && !instance.hasSaveFile
        {
            #log(
                Self.logger, .notice,
                "Resting '\(instance.name, privacy: .public)' stopped: its suspend slot is no longer in the bundle"
            )
            instance.activity.reconcileRest()
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
    func beginArrival(
        kind: VMArrival.Kind, configuration: VMConfiguration, destination: URL,
        staged: VMStagedBundle, write: @escaping (VMStagedBundle) async throws -> Void
    ) -> VMArrival {
        let arrival = VMArrival(
            id: configuration.id, kind: kind, configuration: configuration,
            destinationURL: destination, staged: staged
        ) { [weak self] arrival in
            guard let self else { throw CancellationError() }
            return try await self.settle(arrival, writtenBy: write)
        }
        register(arrival)
        return arrival
    }

    /// Runs `arrival` to its outcome and removes its row, handing a failure to
    /// ``onArrivalFailed`` first.
    private func settle(
        _ arrival: VMArrival, writtenBy write: (VMStagedBundle) async throws -> Void
    ) async throws -> VMInstance {
        do {
            let instance = try await publish(arrival, writtenBy: write)
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
    /// Every outcome a cancel produced is thrown as `CancellationError`.
    private func publish(
        _ arrival: VMArrival, writtenBy write: (VMStagedBundle) async throws -> Void
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
        #log(
            Self.logger, .notice,
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
            #log(
                Self.logger, .error,
                "Could not move the cancelled \(arrival.kind.displayNoun.lowercased(), privacy: .public) of '\(arrival.name, privacy: .public)' to the Trash: \(error.localizedDescription, privacy: .public)"
            )
            if case .success(let bundle) = scanned {
                _ = adopt(bundle, publishing: arrival)
            }
            throw ArrivalError.withdrawalFailed(
                name: arrival.name, reason: error.localizedDescription)
        }
        #log(
            Self.logger, .notice,
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
            #log(
                Self.logger, .warning,
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
            #log(
                Self.logger, .notice,
                "Terminating: abandoning \(arrival.kind.displayNoun, privacy: .public) of '\(arrival.name, privacy: .public)'"
            )
            do {
                try storageService.discardStagedBundle(at: arrival.staged.url)
            } catch {
                #log(
                    Self.logger, .warning,
                    "Failed to discard the staged bundle for '\(arrival.name, privacy: .public)' during termination: \(error.localizedDescription, privacy: .public)"
                )
            }
            removeArrival(arrival)
        }
    }
}
