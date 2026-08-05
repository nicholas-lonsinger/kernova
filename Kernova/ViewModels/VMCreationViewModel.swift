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
    case localFile(path: String, bookmark: Data?)

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

    init(
        catalogService: any RestoreImageCatalogProviding = RestoreImageCatalogService(),
        probeService: any RestoreImageProbing = RestoreImageProbeService(),
        localImageInspector: any LocalRestoreImageInspecting = LocalRestoreImageInspector(),
        ipswService: any IPSWProviding = IPSWService()
    ) {
        self.catalogService = catalogService
        self.probeService = probeService
        self.localImageInspector = localImageInspector
        self.ipswService = ipswService
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
    var isoPath: String?
    var kernelPath: String?
    var initrdPath: String?
    var kernelCommandLine: String?

    /// Security bookmarks paired with the panel-picked paths above; each is set
    /// alongside its path at pick time.
    var isoBookmark: Data?
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
                // Reached only when `bootConfigValid` said no, and the conflict
                // is the one thing that makes it say no for macOS.
                return "Resolve the file conflict above to continue."
            case .linux:
                switch selectedBootMode {
                case .efi: return "Select an ISO image to continue."
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
            // A pinned pick is inseparable from its source, so the only macOS
            // blocker left is the download-destination conflict.
            !shouldShowOverwriteWarning
        case .linux:
            switch selectedBootMode {
            case .efi: isoPath != nil
            case .linuxKernel: kernelPath != nil
            case .macOS: false
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

    /// The Downloads path for a given IPSW filename.
    ///
    /// Asks the system for the Downloads location rather than assuming a
    /// home-relative layout: under the sandbox this resolves through the
    /// container's `Downloads` symlink, which the downloads.read-write
    /// entitlement covers — no save panel or bookmark needed.
    ///
    /// `filename` must be one path component: callers derive it through
    /// ``RestoreImageFilename``, which is what keeps a URL-supplied name from
    /// walking out of Downloads.
    static func downloadPath(forFilename filename: String) -> String {
        guard
            let downloads = FileManager.default.urls(
                for: .downloadsDirectory, in: .userDomainMask
            ).first
        else {
            logger.fault("No Downloads directory in userDomainMask")
            assertionFailure("FileManager returned no Downloads directory")
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads")
                .appendingPathComponent(filename)
                .path(percentEncoded: false)
        }
        return downloads.appendingPathComponent(filename).path(percentEncoded: false)
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
    /// is `nil` when the bookmark could not be created.
    func selectLocalFile(path: String, bookmark: Data?) {
        ipswSelection = .localFile(path: path, bookmark: bookmark)
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

    // MARK: - Apply Defaults

    func applyOSDefaults() {
        cpuCount = selectedOS.defaultCPUCount
        memoryInGB = selectedOS.defaultMemoryInGB
        diskSizeInGB = VMGuestOS.defaultDiskSizeInGB
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
        case .localFile(let path, let bookmark):
            MacOSInstallContext(
                source: .localFile,
                localIPSWPath: path,
                localIPSWBookmark: bookmark
            )
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
    /// decision is pending.
    ///
    /// No bookmark: the file was adopted without a panel, so there is no grant
    /// to capture — and none is needed, the Downloads location being
    /// entitlement-covered.
    func useExistingDownloadFile(at path: String) {
        ipswSelection = .localFile(path: path, bookmark: nil)
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

        useExistingDownloadFile(at: path)
        return .adopted(inspected)
    }

    // MARK: - Build Configuration

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

        // For an EFI install that picked an ISO, the installer goes in as
        // `storageDevices[0]` so EFI boots it ahead of the main disk. Other boot
        // modes leave the list nil so the builder synthesizes the default disk.
        var storageDisks: [StorageDisk]? = nil
        if selectedBootMode == .efi, let isoPath, !isoPath.isEmpty {
            let installerDisk = StorageDisk(
                path: isoPath,
                readOnly: true,
                label: URL(fileURLWithPath: isoPath).deletingPathExtension().lastPathComponent,
                bookmark: isoBookmark
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

        return VMConfiguration(
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
    }
}
