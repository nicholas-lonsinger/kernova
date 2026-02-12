import Foundation
import Virtualization

/// Runtime wrapper around a VM configuration, its backing virtual machine, and current status.
@MainActor
@Observable
final class VMInstance: Identifiable {

    // MARK: - Properties

    let instanceID: UUID
    var configuration: VMConfiguration
    var status: VMStatus
    var virtualMachine: VZVirtualMachine?
    let bundleURL: URL

    /// Installation progress (0.0–1.0) when installing macOS.
    var installProgress: Double = 0

    /// Detailed status text shown below the progress bar during installation.
    var installStatusDetail: String = ""

    /// Error message if the VM entered an error state.
    var errorMessage: String?

    nonisolated var id: UUID { instanceID }
    var name: String { configuration.name }

    // MARK: - Delegate

    private var delegateAdapter: VMDelegateAdapter?

    // MARK: - Initializer

    init(configuration: VMConfiguration, bundleURL: URL, status: VMStatus = .stopped) {
        self.instanceID = configuration.id
        self.configuration = configuration
        self.bundleURL = bundleURL
        self.status = status
    }

    // MARK: - VM Bundle Paths

    var diskImageURL: URL {
        bundleURL.appendingPathComponent("Disk.asif")
    }

    var auxiliaryStorageURL: URL {
        bundleURL.appendingPathComponent("AuxiliaryStorage")
    }

    var hardwareModelURL: URL {
        bundleURL.appendingPathComponent("HardwareModel")
    }

    var machineIdentifierURL: URL {
        bundleURL.appendingPathComponent("MachineIdentifier")
    }

    var restoreImageURL: URL {
        bundleURL.appendingPathComponent("RestoreImage.ipsw")
    }

    var saveFileURL: URL {
        bundleURL.appendingPathComponent("SaveFile.vzvmsave")
    }

    var hasSaveFile: Bool {
        FileManager.default.fileExists(atPath: saveFileURL.path)
    }

    /// `true` when the VM is paused-to-disk but has no live `VZVirtualMachine` in memory.
    var isColdPaused: Bool {
        status == .paused && virtualMachine == nil
    }

    // MARK: - Delegate Setup

    func setupDelegate() {
        guard let vm = virtualMachine else { return }
        let adapter = VMDelegateAdapter(instance: self)
        vm.delegate = adapter
        self.delegateAdapter = adapter
    }
}

// MARK: - VZVirtualMachineDelegate Adapter

/// Bridges `VZVirtualMachineDelegate` callbacks to update the `VMInstance` status.
@MainActor
private final class VMDelegateAdapter: NSObject, VZVirtualMachineDelegate {
    weak var instance: VMInstance?

    init(instance: VMInstance) {
        self.instance = instance
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated {
            instance?.status = .stopped
            instance?.virtualMachine = nil
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        MainActor.assumeIsolated {
            instance?.status = .error
            instance?.errorMessage = error.localizedDescription
            instance?.virtualMachine = nil
        }
    }
}
