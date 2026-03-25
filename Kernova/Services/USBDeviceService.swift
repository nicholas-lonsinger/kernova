import Foundation
import Virtualization
import os

/// Manages runtime USB mass storage device attach/detach via XHCI controller.
@MainActor
final class USBDeviceService: USBDeviceProviding {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "USBDeviceService")

    func attach(
        diskImagePath: String,
        readOnly: Bool,
        to instance: VMInstance
    ) async throws -> USBDeviceInfo {
        guard let vm = instance.virtualMachine else {
            Self.logger.error("Cannot attach USB device: no virtual machine for '\(instance.name, privacy: .public)'")
            throw USBDeviceError.noVirtualMachine
        }
        guard let controller = vm.usbControllers.first else {
            Self.logger.error("Cannot attach USB device: no USB controller for '\(instance.name, privacy: .public)'")
            throw USBDeviceError.noUSBController
        }

        let resolved: PathValidation.ResolvedPath
        do {
            resolved = try PathValidation.resolveFile(at: diskImagePath, requireWritable: !readOnly)
            resolved.logResolution(logger: Self.logger, context: "USB disk image")
        } catch let error as PathValidation.Failure {
            switch error {
            case .notFound:
                Self.logger.error("USB disk image not found at '\(diskImagePath, privacy: .public)'")
                throw USBDeviceError.diskImageNotFound(diskImagePath)
            case .unexpectedType:
                Self.logger.error("USB disk image path is a directory: '\(diskImagePath, privacy: .public)'")
                throw USBDeviceError.diskImageIsDirectory(diskImagePath)
            case .notWritable:
                Self.logger.error("USB disk image is not writable: '\(diskImagePath, privacy: .public)'")
                throw USBDeviceError.diskImageNotWritable(diskImagePath)
            case .notReadable:
                throw USBDeviceError.diskImageNotFound(diskImagePath)
            }
        }

        let attachment: VZDiskImageStorageDeviceAttachment
        do {
            attachment = try VZDiskImageStorageDeviceAttachment(url: resolved.url, readOnly: readOnly)
        } catch {
            Self.logger.error("Failed to create disk attachment for '\(diskImagePath, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let usbConfig = VZUSBMassStorageDeviceConfiguration(attachment: attachment)
        let usbDevice = VZUSBMassStorageDevice(configuration: usbConfig)

        do {
            try await controller.attach(device: usbDevice)
        } catch {
            Self.logger.error("Failed to attach USB device '\(resolved.url.lastPathComponent, privacy: .public)' to VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            throw error
        }

        let info = USBDeviceInfo(id: usbConfig.uuid, path: diskImagePath, readOnly: readOnly)

        Self.logger.notice("Attached USB device '\(resolved.url.lastPathComponent, privacy: .public)' to VM '\(instance.name, privacy: .public)' (readOnly: \(readOnly, privacy: .public))")
        return info
    }

    func detach(
        deviceInfo: USBDeviceInfo,
        from instance: VMInstance
    ) async throws {
        guard let vm = instance.virtualMachine else {
            Self.logger.error("Cannot detach USB device: no virtual machine for '\(instance.name, privacy: .public)'")
            throw USBDeviceError.noVirtualMachine
        }
        guard let controller = vm.usbControllers.first else {
            Self.logger.error("Cannot detach USB device: no USB controller for '\(instance.name, privacy: .public)'")
            throw USBDeviceError.noUSBController
        }

        guard let usbDevice = controller.usbDevices.first(where: { $0.uuid == deviceInfo.id }) else {
            Self.logger.error("USB device '\(deviceInfo.displayName, privacy: .public)' not found on controller for VM '\(instance.name, privacy: .public)'")
            throw USBDeviceError.deviceNotFound
        }

        do {
            try await controller.detach(device: usbDevice)
        } catch {
            Self.logger.error("Failed to detach USB device '\(deviceInfo.displayName, privacy: .public)' from VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            throw error
        }

        Self.logger.notice("Detached USB device '\(deviceInfo.displayName, privacy: .public)' from VM '\(instance.name, privacy: .public)'")
    }
}

// MARK: - Errors

enum USBDeviceError: LocalizedError {
    case noVirtualMachine
    case noUSBController
    case diskImageNotFound(String)
    case diskImageIsDirectory(String)
    case diskImageNotWritable(String)
    case deviceNotFound

    var errorDescription: String? {
        switch self {
        case .noVirtualMachine:
            "No virtual machine is running."
        case .noUSBController:
            "No USB controller is available. Restart the VM to enable USB device support."
        case .diskImageNotFound(let path):
            "Disk image not found at \(path)."
        case .diskImageIsDirectory(let path):
            "Path is a directory, not a file: \(path)."
        case .diskImageNotWritable(let path):
            "Disk image is not writable: \(path). Try attaching as read-only."
        case .deviceNotFound:
            "The USB device could not be found on the controller."
        }
    }
}
