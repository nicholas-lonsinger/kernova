import Foundation
import Virtualization
import os

/// Wizard steps for creating a new VM.
enum VMCreationStep: String, CaseIterable, Sendable {
    case osSelection
    case bootConfig
    case resources
    case review

    var title: String {
        switch self {
        case .osSelection: "OS"
        case .bootConfig: "Boot"
        case .resources: "Resources"
        case .review: "Review"
        }
    }
}

/// IPSW source selection for macOS VM creation.
enum IPSWSource: Sendable {
    case downloadLatest
    case catalogVersion
    case customURL
    case localFile

    /// Whether this source obtains the image over the network, and so shares
    /// the download destination, overwrite warning, and resume affordance.
    var downloadsImage: Bool {
        switch self {
        case .downloadLatest, .catalogVersion, .customURL: true
        case .localFile: false
        }
    }
}

/// The chosen source together with what that source needs to install, so a
/// source cannot be current without its pick.
///
/// Set only through ``VMCreationViewModel``'s `select` methods. `Equatable` but
/// not `Hashable` — the payloads are not — so keys go on ``IPSWSource``.
enum IPSWSelection: Sendable, Equatable {
    case downloadLatest
    case catalogVersion(RestoreImageCatalogEntry)
    case customURL(ProbedRestoreImage)
    case localFile(LocalRestoreImage)

    /// Which radio this selection lights, independent of what it carries.
    var source: IPSWSource {
        switch self {
        case .downloadLatest: .downloadLatest
        case .catalogVersion: .catalogVersion
        case .customURL: .customURL
        case .localFile: .localFile
        }
    }
}

/// Where a Linux guest's installer image comes from, together with what that
/// choice carries, so a source cannot be current without its pick.
///
/// Set only through ``VMCreationViewModel``'s `select` methods.
enum LinuxImageSelection: Sendable, Equatable {
    /// A distribution from the bundled catalog. Nothing is on disk yet — the
    /// image is resolved and downloaded after the VM is created.
    case catalogEntry(LinuxImageCatalogEntry)
    /// An ISO at a URL the user supplied, with the length the wizard's check
    /// read for it — shown, never persisted, since the download re-reads it for
    /// the ceiling it holds the transfer to.
    case customURL(image: CustomLinuxImage, sizeBytes: UInt64)
    /// An ISO already on this Mac, with the grant minted for it at pick time.
    case localISO(path: String, bookmark: Data?)
}

/// State machine for the VM creation wizard.
@MainActor
@Observable
final class VMCreationViewModel {
    private static let logger = Logger(subsystem: "app.kernova", category: "VMCreationViewModel")

    /// Backs the "Choose a Version…" picker.
    ///
    /// Read only while that source is selected; the other two sources never
    /// touch it.
    let catalogService: any RestoreImageCatalogProviding

    /// Backs the "Paste an IPSW URL…" sheet's pre-download check; its size read
    /// alone also sizes the image "Download Latest" would fetch.
    let probeService: any RestoreImageProbing

    /// Reads an IPSW already on disk before the wizard adopts it.
    let localImageInspector: any LocalRestoreImageInspecting

    /// Names what "Download Latest" will fetch, for the wizard to show.
    let ipswService: any IPSWProviding

    /// Backs the Linux "Choose a Distribution…" picker.
    let linuxCatalogService: any LinuxImageCatalogProviding

    /// Backs the Linux "Image URL…" sheet's pre-download check — the same
    /// service the install pipeline resolves through, so a URL is admitted on
    /// one set of rules at both ends.
    let linuxImageResolveService: any LinuxImageResolving

    init(
        catalogService: any RestoreImageCatalogProviding = RestoreImageCatalogService(),
        probeService: any RestoreImageProbing = RestoreImageProbeService(),
        localImageInspector: any LocalRestoreImageInspecting = LocalRestoreImageInspector(),
        ipswService: any IPSWProviding = IPSWService(),
        linuxCatalogService: any LinuxImageCatalogProviding = LinuxImageCatalogService(),
        linuxImageResolveService: any LinuxImageResolving = LinuxImageResolveService()
    ) {
        self.catalogService = catalogService
        self.probeService = probeService
        self.localImageInspector = localImageInspector
        self.ipswService = ipswService
        self.linuxCatalogService = linuxCatalogService
        self.linuxImageResolveService = linuxImageResolveService
    }

    // MARK: - Wizard State

    var currentStep: VMCreationStep = .osSelection

    // MARK: - Step 1: OS Selection

    var selectedOS: VMGuestOS = .macOS

    // MARK: - Step 2: Boot Config

    var selectedBootMode: VMBootMode = .efi
    private(set) var ipswSelection: IPSWSelection = .downloadLatest

    /// Which source is current, for the radios and the source labels.
    var ipswSource: IPSWSource { ipswSelection.source }

    /// What "Download Latest" will fetch, once ``loadLatestImageDetails()`` has
    /// answered; `nil` until then, and after a lookup that failed.
    ///
    /// A preview on the terms ``LatestRestoreImage`` states, read for display
    /// and to name the download destination.
    private(set) var latestImage: LatestRestoreImage?

    /// How large ``latestImage`` is, when the server reported a size.
    ///
    /// A second read, so it can be absent while the version and build are
    /// known; the wizard then names those alone.
    private(set) var latestImageSizeBytes: UInt64?

    /// The lookup in flight, so a second trigger joins it instead of starting
    /// another.
    private var latestImageTask: Task<Void, Never>?

    /// The local-file inspection in flight, so a re-entered boot-config step
    /// can pick its watch back up after the VC that started it was torn down.
    private(set) var localFileInspectionTask: Task<Void, Never>?

    /// Bumped on every ``selectLocalFile(path:bookmark:)`` call; only the task
    /// started at the current generation clears ``localFileInspectionTask``
    /// when it finishes.
    ///
    /// A re-pick cancels the previous task, but `VZMacOSRestoreImage` does not
    /// honor cancellation, so the superseded read keeps running and can finish
    /// *after* the newer one has already started — the ordinary ordering, not
    /// adversarial timing. An unconditional clear there would nil out the
    /// newer task's still-in-flight handle, leaving a VC that reads it
    /// afterward with nothing to await.
    private var localFileInspectionGeneration = 0

    /// The last catalog pick, kept after the source moves off it so the version
    /// picker re-opens on it.
    private(set) var lastCatalogPick: RestoreImageCatalogEntry?
    /// The last checked URL, on the same terms.
    private(set) var lastPastedImage: ProbedRestoreImage?
    /// Always inside Downloads — there is no custom-destination picker.
    ///
    /// Every download source names the file through ``RestoreImageFilename``;
    /// "Download Latest" starts on the fixed fallback and adopts the looked-up
    /// image's name once ``loadLatestImageDetails()`` answers.
    var ipswDownloadPath: String = VMCreationViewModel.defaultIPSWDownloadPath {
        didSet {
            if ipswDownloadPath != confirmedOverwritePath {
                confirmedOverwritePath = nil
            }
        }
    }
    private var confirmedOverwritePath: String?

    /// The Linux EFI image, once chosen; `nil` until the user picks one.
    private(set) var linuxSelection: LinuxImageSelection?

    var kernelPath: String?
    var initrdPath: String?
    var kernelCommandLine: String?

    /// Security bookmarks paired with the panel-picked paths above; each is set
    /// alongside its path at pick time.
    var kernelBookmark: Data?
    var initrdBookmark: Data?

    // MARK: - Step 3: Resources

    var vmName: String = "My Virtual Machine"
    var cpuCount: Int = 4
    var memoryInGB: Int = 8
    var diskSizeInGB: Int = 100
    var networkEnabled: Bool = true

    // MARK: - Step 4: Review

    /// Whether to auto-start the VM immediately after the wizard creates it,
    /// backing the "Start this VM after creation" toggle on the Review step.
    var startAfterCreate: Bool = true

    // MARK: - Navigation

    var validationMessage: String? {
        guard !canAdvance else { return nil }
        switch currentStep {
        case .osSelection, .review:
            return nil
        case .bootConfig:
            switch selectedOS {
            case .macOS:
                if shouldShowOverwriteWarning {
                    return "Resolve the file conflict above to continue."
                }
                if case .localFile(let image) = ipswSelection {
                    switch image.inspection {
                    case .pending:
                        return "Checking the selected restore image…"
                    case .unusable(.unsupported):
                        return "Choose a restore image this Mac can install."
                    case .unusable(.unreadable):
                        return "Choose a file this Mac can read as a restore image."
                    case .usable:
                        return nil
                    }
                }
                return nil
            case .linux:
                switch selectedBootMode {
                case .efi: return "Select an installer image to continue."
                case .linuxKernel: return "Select a kernel image to continue."
                case .macOS: return "Invalid boot configuration."
                }
            }
        case .resources:
            return "Enter a name for your virtual machine."
        }
    }

    var canAdvance: Bool {
        switch currentStep {
        case .osSelection:
            true
        case .bootConfig:
            bootConfigValid
        case .resources:
            !vmName.trimmingCharacters(in: .whitespaces).isEmpty
        case .review:
            true
        }
    }

    var canCreate: Bool {
        !vmName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var effectiveBootMode: VMBootMode {
        switch selectedOS {
        case .macOS: .macOS
        case .linux: selectedBootMode
        }
    }

    private var bootConfigValid: Bool {
        switch selectedOS {
        case .macOS:
            if shouldShowOverwriteWarning { return false }
            if case .localFile(let image) = ipswSelection {
                return image.inspection.usable != nil
            }
            return true
        case .linux:
            switch selectedBootMode {
            case .efi: return linuxSelection != nil
            case .linuxKernel: return kernelPath != nil
            case .macOS: return false
            }
        }
    }

    func goNext() {
        guard let nextStep = nextStep else { return }
        currentStep = nextStep
    }

    func goBack() {
        guard let prevStep = previousStep else { return }
        currentStep = prevStep
    }

    private var nextStep: VMCreationStep? {
        let allSteps = VMCreationStep.allCases
        guard let currentIndex = allSteps.firstIndex(of: currentStep),
            currentIndex + 1 < allSteps.count
        else { return nil }
        return allSteps[currentIndex + 1]
    }

    private var previousStep: VMCreationStep? {
        let allSteps = VMCreationStep.allCases
        guard let currentIndex = allSteps.firstIndex(of: currentStep),
            currentIndex > 0
        else { return nil }
        return allSteps[currentIndex - 1]
    }

    // MARK: - Defaults

    static var defaultIPSWDownloadPath: String {
        downloadPath(forFilename: RestoreImageFilename.fallback)
    }

    /// Where every image the wizard downloads lands.
    ///
    /// Asks the system for the Downloads location rather than assuming a
    /// home-relative layout: under the sandbox this resolves through the
    /// container's `Downloads` symlink, which the downloads.read-write
    /// entitlement covers — no save panel or bookmark needed.
    static var downloadsDirectory: URL {
        guard
            let downloads = FileManager.default.urls(
                for: .downloadsDirectory, in: .userDomainMask
            ).first
        else {
            logger.fault("No Downloads directory in userDomainMask")
            assertionFailure("FileManager returned no Downloads directory")
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads")
        }
        return downloads
    }

    /// The Downloads path for a given image filename.
    ///
    /// `filename` must be one path component: callers derive it through
    /// ``SafeFilename``, which is what keeps a URL-supplied name from walking
    /// out of Downloads.
    static func downloadPath(forFilename filename: String) -> String {
        downloadsDirectory.appendingPathComponent(filename).path(percentEncoded: false)
    }

    // MARK: - Source Selection

    /// Commits a catalog pick, moving the download destination to Apple's own
    /// filename for that build.
    ///
    /// Per-build destinations are what keep a pick honest: a single fixed
    /// filename would let an already-downloaded image of a *different* version
    /// satisfy the download step, installing something other than what the
    /// wizard shows.
    func selectCatalogEntry(_ entry: RestoreImageCatalogEntry) {
        ipswSelection = .catalogVersion(entry)
        lastCatalogPick = entry
        ipswDownloadPath = Self.downloadPath(forFilename: entry.suggestedFilename)
    }

    /// Commits a checked URL, on the same per-image destination terms as a
    /// catalog pick.
    func selectPastedImage(_ image: ProbedRestoreImage) {
        ipswSelection = .customURL(image)
        lastPastedImage = image
        ipswDownloadPath = Self.downloadPath(forFilename: image.suggestedFilename)
    }

    /// Commits the "Download Latest" source, naming the destination for the
    /// image the lookup found — or the fixed fallback while none has answered.
    ///
    /// The one operation that drops both sheet seeds: choosing to install
    /// whatever is newest retracts the earlier "install *this* build" answers.
    func selectDownloadLatest() {
        ipswSelection = .downloadLatest
        lastCatalogPick = nil
        lastPastedImage = nil
        ipswDownloadPath = Self.downloadPath(
            forFilename: latestImage?.suggestedFilename ?? RestoreImageFilename.fallback)
    }

    /// Commits a panel-picked file together with the grant minted for it, which
    /// is `nil` when the bookmark could not be created, then starts inspecting
    /// it for the version, build and size a downloaded image already shows.
    ///
    /// The selection carries `.pending` until the inspection lands with a
    /// verdict — ``bootConfigValid`` blocks Next on a local file until that
    /// verdict is ``LocalRestoreImageInspection/usable(_:)``.
    func selectLocalFile(path: String, bookmark: Data?) {
        localFileInspectionTask?.cancel()
        ipswSelection = .localFile(LocalRestoreImage(path: path, bookmark: bookmark))
        localFileInspectionGeneration += 1
        let generation = localFileInspectionGeneration
        let inspector = localImageInspector
        let task = Task { [weak self] in
            defer {
                // Only the current generation's finish clears the handle — a
                // superseded task finishing after it must leave the newer
                // task's handle in place.
                if let self, self.localFileInspectionGeneration == generation {
                    self.localFileInspectionTask = nil
                }
            }
            let scope = bookmark.flatMap { ScopedAccess(bookmark: $0) }
            defer { scope?.release() }
            let url = scope?.url ?? URL(fileURLWithPath: path)
            let inspection: LocalRestoreImageInspection
            do {
                let inspected = try await inspector.inspect(url)
                inspection = inspected.isSupportedOnThisHost ? .usable(inspected) : .unusable(.unsupported)
            } catch {
                if Task.isCancelled { return }
                Self.logger.warning(
                    "Could not inspect local restore image at '\(url.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                inspection = .unusable((error as? LocalRestoreImageError) ?? .unreadable)
            }
            guard let self, !Task.isCancelled else { return }
            // A newer pick for the same path, or one for a different path
            // entirely, must not be overwritten by a slow, stale inspection.
            guard case .localFile(var image) = self.ipswSelection,
                image.path == path,
                image.inspection == .pending
            else { return }
            image.inspection = inspection
            self.ipswSelection = .localFile(image)
        }
        localFileInspectionTask = task
    }

    // MARK: - Linux Image Selection

    /// Commits a distribution from the bundled catalog.
    ///
    /// Nothing is downloaded here: the wizard stays offline, and the image is
    /// resolved and fetched once the VM exists.
    func selectLinuxCatalogEntry(_ entry: LinuxImageCatalogEntry) {
        linuxSelection = .catalogEntry(entry)
    }

    /// Commits a checked URL, on the same "downloaded after the VM exists"
    /// terms as a catalog pick.
    func selectLinuxCustomURL(_ image: CustomLinuxImage, sizeBytes: UInt64) {
        linuxSelection = .customURL(image: image, sizeBytes: sizeBytes)
    }

    /// Commits a panel-picked ISO together with the grant minted for it, which
    /// is `nil` when the bookmark could not be created.
    func selectLocalISO(path: String, bookmark: Data?) {
        linuxSelection = .localISO(path: path, bookmark: bookmark)
    }

    // MARK: - Latest Image Lookup

    /// Looks up what "Download Latest" would fetch, so the wizard can name the
    /// version, build, size and destination filename that source otherwise
    /// leaves unsaid.
    ///
    /// Idempotent: calls while a lookup runs join it, calls after one succeeded
    /// do nothing, and one that failed retries on the next call — a wizard the
    /// user is walking through triggers this more than once. A failure is not
    /// surfaced: the wizard names the download destination alone, which is what
    /// it showed before the lookup existed.
    ///
    /// - Returns: the lookup to await for its result, or `nil` when the details
    ///   are already known and nothing had to run.
    @discardableResult
    func loadLatestImageDetails() -> Task<Void, Never>? {
        if let latestImageTask { return latestImageTask }
        guard latestImage == nil else { return nil }
        let ipswService = self.ipswService
        let probeService = self.probeService
        let task = Task { [weak self] in
            defer { self?.latestImageTask = nil }
            let image: LatestRestoreImage
            do {
                image = try await ipswService.fetchLatestRestoreImage()
            } catch {
                Self.logger.warning(
                    "Could not look up the latest restore image: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
            // The size is a separate request, and the version and build are
            // worth showing without it.
            let sizeBytes = try? await probeService.size(of: image.url)
            guard let self else { return }
            self.latestImage = image
            self.latestImageSizeBytes = sizeBytes
            // Only while the source is still current — a pick made while the
            // lookup ran named its own destination.
            if self.ipswSelection == .downloadLatest {
                self.ipswDownloadPath = Self.downloadPath(
                    forFilename: image.suggestedFilename)
            }
        }
        latestImageTask = task
        return task
    }

    // MARK: - Overwrite Warning

    var ipswDownloadPathFileExists: Bool {
        FileManager.default.fileExists(atPath: ipswDownloadPath)
    }

    var shouldShowOverwriteWarning: Bool {
        ipswSource.downloadsImage
            && ipswDownloadPathFileExists
            && confirmedOverwritePath != ipswDownloadPath
    }

    // MARK: - Install Context

    /// Snapshots the wizard's macOS install choice into a persistable
    /// `MacOSInstallContext`.
    ///
    /// The install pipeline reads from the VM's bundle, not the wizard, on every
    /// Start until the install completes and the context is cleared.
    func buildInstallContext() -> MacOSInstallContext {
        switch ipswSelection {
        case .downloadLatest:
            MacOSInstallContext(
                source: .downloadLatest,
                downloadDestinationPath: ipswDownloadPath,
                requestedFreshDownload: requestedFreshDownload
            )
        case .catalogVersion(let entry):
            MacOSInstallContext(
                source: .catalogVersion,
                downloadDestinationPath: ipswDownloadPath,
                requestedFreshDownload: requestedFreshDownload,
                remoteURL: entry.url,
                version: entry.version,
                build: entry.build
            )
        case .customURL(let image):
            MacOSInstallContext(
                source: .customURL,
                downloadDestinationPath: ipswDownloadPath,
                requestedFreshDownload: requestedFreshDownload,
                remoteURL: image.url,
                version: image.version,
                build: image.build
            )
        case .localFile(let image):
            MacOSInstallContext(
                source: .localFile,
                localIPSWPath: image.path,
                localIPSWBookmark: image.bookmark
            )
        }
    }

    /// Snapshots a Linux image pick that has still to be downloaded into a
    /// persistable `LinuxInstallContext`, or `nil` when nothing is.
    ///
    /// A local ISO is already on disk and goes straight into `storageDisks`;
    /// the two download sources leave work for the post-create pipeline. Gated
    /// on the EFI boot mode alongside its siblings in ``buildConfiguration()``,
    /// so a pick made under EFI does not follow a switch to Linux-kernel boot
    /// onto a VM that never boots an installer.
    ///
    /// A catalog pick gets no destination: only a resolution just before the
    /// download knows which URL the mirror is serving, and the destination is
    /// named for that URL. A pasted URL is known from the moment it is
    /// admitted, so its destination is too.
    func buildLinuxInstallContext() -> LinuxInstallContext? {
        guard selectedBootMode == .efi else { return nil }
        switch linuxSelection {
        case .catalogEntry(let entry):
            return LinuxInstallContext(source: .catalogEntry(entry))
        case .customURL(let image, _):
            return LinuxInstallContext(
                source: .customURL(image),
                downloadDestinationPath: Self.downloadPath(
                    forFilename: LinuxImageFilename.destination(for: image.url)))
        case .localISO, nil:
            return nil
        }
    }

    /// Whether the user confirmed overwriting the destination the wizard is
    /// currently pointing at.
    private var requestedFreshDownload: Bool {
        confirmedOverwritePath == ipswDownloadPath
    }

    // MARK: - Resume Detection

    /// `true` when the chosen download destination has an associated
    /// `.kernovadownload` bundle from a prior interrupted download that still
    /// holds its partial bytes, *and* no completed IPSW already exists at the
    /// path.
    ///
    /// The bytes check (`isResumable` rather than `exists`) keeps a husk left by
    /// a failed disposal from offering a resume with nothing behind it.
    var hasResumableDownload: Bool {
        guard ipswSource.downloadsImage,
            !ipswDownloadPathFileExists
        else { return false }
        let bundleURL = DownloadService.resumeBundleURL(for: URL(fileURLWithPath: ipswDownloadPath))
        return DownloadBundle(url: bundleURL).isResumable
    }

    func confirmOverwrite() {
        confirmedOverwritePath = ipswDownloadPath
    }

    /// Adopts the file at `path`, which the caller inspected or the user
    /// explicitly accepted.
    ///
    /// The caller supplies the path it showed the user rather than this reading
    /// ``ipswDownloadPath``, which the latest-image lookup can move while a
    /// decision is pending. `inspected` is required — both call sites already
    /// inspected the file, and a default would let a route silently lose the
    /// metadata the card and the Review step show for it.
    ///
    /// No bookmark: the file was adopted without a panel, so there is no grant
    /// to capture — and none is needed, the Downloads location being
    /// entitlement-covered.
    func useExistingDownloadFile(at path: String, inspected: InspectedRestoreImage) {
        ipswSelection = .localFile(
            LocalRestoreImage(path: path, bookmark: nil, inspection: .usable(inspected)))
    }

    /// The build the wizard is currently promising — a pinned pick's, or the
    /// looked-up latest one — or `nil` while no particular image is named.
    var expectedBuild: String? {
        switch ipswSelection {
        case .catalogVersion(let entry): entry.build
        case .customURL(let image): image.build
        case .downloadLatest: latestImage?.build
        case .localFile: nil
        }
    }

    /// What inspecting the file at the download destination established.
    enum ExistingFileVerdict: Equatable {
        /// Adopted. Carries what the file turned out to be.
        case adopted(InspectedRestoreImage)
        /// A different build than the one the wizard is showing; **not** adopted,
        /// so the user decides.
        case mismatch(expected: String, found: InspectedRestoreImage)
        /// Not adoptable at all; the message is user-facing.
        case unusable(message: String)
        /// The caller cancelled while the inspection ran; nothing was changed,
        /// and the verdict describes a destination the wizard may have left.
        case cancelled
    }

    /// Checks the file at `path` — the caller's snapshot of the destination it
    /// showed the user — and adopts it only if it is the image the wizard is
    /// promising.
    ///
    /// Without this, "Use Existing File" takes whatever is at the path. A file
    /// that is a *valid but different* macOS installs silently — the same
    /// wrong-image failure the per-build destination fixes for downloads, which
    /// a stale or hand-placed file reintroduces.
    ///
    /// Reading a multi-gigabyte image takes seconds, in which the user can pick
    /// another source or leave the step — a cancelled call returns
    /// ``ExistingFileVerdict/cancelled`` having changed nothing — and the
    /// latest-image lookup can move ``ipswDownloadPath`` and ``expectedBuild``:
    /// both the verdict and any adoption describe the file the user was asked
    /// about, so the path comes in as the caller's snapshot and the build is
    /// snapshotted before the inspection.
    func adoptExistingDownloadFile(at path: String) async -> ExistingFileVerdict {
        let expectedBuild = expectedBuild
        let url = URL(fileURLWithPath: path)
        let inspected: InspectedRestoreImage
        do {
            inspected = try await localImageInspector.inspect(url)
        } catch {
            if Task.isCancelled { return .cancelled }
            let message =
                (error as? LocalRestoreImageError)?.errorDescription
                ?? LocalRestoreImageError.unreadable.errorDescription
            return .unusable(message: message ?? "That file isn't a usable restore image.")
        }
        if Task.isCancelled { return .cancelled }

        guard inspected.isSupportedOnThisHost else {
            return .unusable(
                message: LocalRestoreImageError.unsupported.errorDescription
                    ?? "That restore image can't install on this Mac.")
        }

        if let expectedBuild, expectedBuild != inspected.build {
            return .mismatch(expected: expectedBuild, found: inspected)
        }

        useExistingDownloadFile(at: path, inspected: inspected)
        return .adopted(inspected)
    }

    // MARK: - Build Configuration

    /// The complete configuration the wizard hands to the create verb — every
    /// field the new VM is written with, including the setup intent its first
    /// Start reads back off the bundle.
    func buildConfiguration() -> VMConfiguration {
        let bootMode = effectiveBootMode

        // Generate a stable MAC address so save/restore uses a consistent config
        let macAddress: String? =
            networkEnabled
            ? VZMACAddress.randomLocallyAdministered().string
            : nil

        let genericMachineIdentifierData: Data? =
            (bootMode == .efi || bootMode == .linuxKernel)
            ? VZGenericMachineIdentifier().dataRepresentation
            : nil

        // For an EFI install from an ISO already on disk, the installer goes in
        // as `storageDevices[0]` so EFI boots it ahead of the main disk. Other
        // boot modes leave the list nil so the builder synthesizes the default
        // disk — as does a catalog pick, whose ISO does not exist yet.
        var storageDisks: [StorageDisk]? = nil
        if selectedBootMode == .efi, case .localISO(let path, let bookmark) = linuxSelection {
            let installerDisk = StorageDisk(
                path: path,
                readOnly: true,
                label: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                bookmark: bookmark
            )
            let mainDisk = StorageDisk(
                path: "Disk.asif",
                readOnly: false,
                label: "Main Disk",
                isInternal: true,
                kind: .virtio
            )
            storageDisks = [installerDisk, mainDisk]
        }

        var configuration = VMConfiguration(
            name: vmName.trimmingCharacters(in: .whitespaces),
            guestOS: selectedOS,
            bootMode: bootMode,
            cpuCount: cpuCount,
            memorySizeInGB: memoryInGB,
            diskSizeInGB: diskSizeInGB,
            networkEnabled: networkEnabled,
            macAddress: macAddress,
            genericMachineIdentifierData: genericMachineIdentifierData,
            kernelPath: selectedBootMode == .linuxKernel ? kernelPath : nil,
            initrdPath: selectedBootMode == .linuxKernel ? initrdPath : nil,
            kernelCommandLine: selectedBootMode == .linuxKernel ? kernelCommandLine : nil,
            kernelBookmark: selectedBootMode == .linuxKernel ? kernelBookmark : nil,
            initrdBookmark: selectedBootMode == .linuxKernel ? initrdBookmark : nil,
            storageDisks: storageDisks
        )

        // Persist the setup intent so the next Start can drive the pipeline
        // without the wizard: a macOS install, or the download of a Linux
        // installer image the user picked from the catalog.
        switch selectedOS {
        case .macOS:
            configuration.installContext = buildInstallContext()
        case .linux:
            configuration.linuxInstallContext = buildLinuxInstallContext()
        }

        return configuration
    }
}
