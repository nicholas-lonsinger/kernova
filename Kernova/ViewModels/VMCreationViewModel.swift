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
            ipswSource == .downloadLatest || ipswPath != nil
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

    // MARK: - Apply Defaults

    func applyOSDefaults() {
        cpuCount = selectedOS.defaultCPUCount
        memoryInGB = selectedOS.defaultMemoryInGB
        diskSizeInGB = selectedOS.defaultDiskSizeInGB
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
            kernelPath: selectedBootMode == .linuxKernel ? kernelPath : nil,
            initrdPath: selectedBootMode == .linuxKernel ? initrdPath : nil,
            kernelCommandLine: selectedBootMode == .linuxKernel ? kernelCommandLine : nil
        )
    }
}
