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
    case localFile
}

/// State machine for the VM creation wizard.
@MainActor
@Observable
final class VMCreationViewModel {
    private static let logger = Logger(subsystem: "app.kernova", category: "VMCreationViewModel")

    // MARK: - Wizard State

    var currentStep: VMCreationStep = .osSelection

    // MARK: - Step 1: OS Selection

    var selectedOS: VMGuestOS = .macOS

    // MARK: - Step 2: Boot Config

    var selectedBootMode: VMBootMode = .efi
    var ipswSource: IPSWSource = .downloadLatest
    var ipswPath: String?
    /// Always the Downloads default — there is no custom-destination picker.
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
    /// alongside its path at pick time. `nil` for paths adopted without a panel
    /// (e.g. "Use Existing File", whose Downloads location the entitlement
    /// already covers).
    var ipswBookmark: Data?
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
                switch ipswSource {
                case .downloadLatest:
                    if shouldShowOverwriteWarning { return "Resolve the file conflict above to continue." }
                case .localFile:
                    if ipswPath == nil { return "Select a restore image file." }
                }
            case .linux:
                switch selectedBootMode {
                case .efi: return "Select an ISO image to continue."
                case .linuxKernel: return "Select a kernel image to continue."
                case .macOS: return "Invalid boot configuration."
                }
            }
            return nil
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
            switch ipswSource {
            case .downloadLatest: !shouldShowOverwriteWarning
            case .localFile: ipswPath != nil
            }
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
        // Ask the system for the Downloads location rather than assuming a
        // home-relative layout: under the sandbox this resolves through the
        // container's `Downloads` symlink, which the downloads.read-write
        // entitlement covers — no save panel or bookmark needed.
        guard
            let downloads = FileManager.default.urls(
                for: .downloadsDirectory, in: .userDomainMask
            ).first
        else {
            logger.fault("No Downloads directory in userDomainMask")
            assertionFailure("FileManager returned no Downloads directory")
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/RestoreImage.ipsw")
                .path(percentEncoded: false)
        }
        return downloads.appendingPathComponent("RestoreImage.ipsw").path(percentEncoded: false)
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
        ipswSource == .downloadLatest
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
        switch ipswSource {
        case .downloadLatest:
            // The `!= nil` guard prevents the meaningless `nil == nil` match (no
            // path AND no confirmation) from setting the flag.
            return MacOSInstallContext(
                source: .downloadLatest,
                downloadDestinationPath: ipswDownloadPath,
                requestedFreshDownload: confirmedOverwritePath != nil
                    && confirmedOverwritePath == ipswDownloadPath
            )
        case .localFile:
            return MacOSInstallContext(
                source: .localFile,
                localIPSWPath: ipswPath,
                localIPSWBookmark: ipswBookmark
            )
        }
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
        guard ipswSource == .downloadLatest,
            !ipswDownloadPathFileExists
        else { return false }
        let bundleURL = IPSWService.resumeBundleURL(for: URL(fileURLWithPath: ipswDownloadPath))
        return IPSWBundle(url: bundleURL).isResumable
    }

    func confirmOverwrite() {
        confirmedOverwritePath = ipswDownloadPath
    }

    func useExistingDownloadFile() {
        ipswSource = .localFile
        ipswPath = ipswDownloadPath
        // Adopted without a panel: no grant to bookmark, and none needed — the
        // Downloads location is entitlement-covered. Clearing also drops any
        // bookmark left over from an earlier local-file pick.
        ipswBookmark = nil
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
