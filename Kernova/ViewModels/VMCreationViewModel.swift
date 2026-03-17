import Foundation
import Virtualization

/// Wizard steps for creating a new VM.
enum VMCreationStep: String, CaseIterable, Identifiable, Sendable {
    case osSelection
    case bootConfig
    case resources
    case review

    var id: String { rawValue }

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

    // MARK: - Wizard State

    var currentStep: VMCreationStep = .osSelection

    // MARK: - Step 1: OS Selection

    var selectedOS: VMGuestOS = .macOS

    // MARK: - Step 2: Boot Config

    var selectedBootMode: VMBootMode = .efi
    var ipswSource: IPSWSource = .downloadLatest
    var ipswPath: String?
    var ipswDownloadPath: String? = VMCreationViewModel.defaultIPSWDownloadPath {
        didSet {
            // Reset overwrite confirmation when the download destination changes
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

    // MARK: - Step 3: Resources

    var vmName: String = "My Virtual Machine"
    var cpuCount: Int = 4
    var memoryInGB: Int = 8
    var diskSizeInGB: Int = 100
    var networkEnabled: Bool = true

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
                    if ipswDownloadPath == nil { return "Choose a download location." }
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
            case .downloadLatest: ipswDownloadPath != nil && !shouldShowOverwriteWarning
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
              currentIndex + 1 < allSteps.count else { return nil }
        return allSteps[currentIndex + 1]
    }

    private var previousStep: VMCreationStep? {
        let allSteps = VMCreationStep.allCases
        guard let currentIndex = allSteps.firstIndex(of: currentStep),
              currentIndex > 0 else { return nil }
        return allSteps[currentIndex - 1]
    }

    // MARK: - Defaults

    static var defaultIPSWDownloadPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/RestoreImage.ipsw")
            .path(percentEncoded: false)
    }

    // MARK: - Apply Defaults

    func applyOSDefaults() {
        cpuCount = selectedOS.defaultCPUCount
        memoryInGB = selectedOS.defaultMemoryInGB
        diskSizeInGB = selectedOS.defaultDiskSizeInGB
    }

    // MARK: - Overwrite Warning

    var ipswDownloadPathFileExists: Bool {
        guard let path = ipswDownloadPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    var shouldShowOverwriteWarning: Bool {
        ipswSource == .downloadLatest
            && ipswDownloadPathFileExists
            && confirmedOverwritePath != ipswDownloadPath
    }

    func confirmOverwrite() {
        confirmedOverwritePath = ipswDownloadPath
    }

    func useExistingDownloadFile() {
        ipswSource = .localFile
        ipswPath = ipswDownloadPath
    }

    // MARK: - Build Configuration

    func buildConfiguration() -> VMConfiguration {
        let bootMode = effectiveBootMode

        // Generate a stable MAC address so save/restore uses a consistent config
        let macAddress: String? = networkEnabled
            ? VZMACAddress.randomLocallyAdministered().string
            : nil

        // For EFI/Linux VMs, generate a stable machine identifier
        let genericMachineIdentifierData: Data? = (bootMode == .efi || bootMode == .linuxKernel)
            ? VZGenericMachineIdentifier().dataRepresentation
            : nil

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
            isoPath: selectedBootMode == .efi ? isoPath : nil,
            kernelPath: selectedBootMode == .linuxKernel ? kernelPath : nil,
            initrdPath: selectedBootMode == .linuxKernel ? initrdPath : nil,
            kernelCommandLine: selectedBootMode == .linuxKernel ? kernelCommandLine : nil
        )
    }
}
