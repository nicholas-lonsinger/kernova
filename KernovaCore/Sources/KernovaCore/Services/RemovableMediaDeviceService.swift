import Foundation
import KernovaLogging

/// Manages runtime USB mass storage device attach/detach via XHCI controller.
@MainActor
package final class RemovableMediaDeviceService: RemovableMediaAttaching {
    package init() {}

    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "RemovableMediaDeviceService")

    package func attach(
        diskImagePath: String,
        attaching file: URL?,
        readOnly: Bool,
        desiredUUID: UUID?,
        to instance: VMInstance
    ) async throws -> RemovableMediaDeviceInfo {
        let name = URL(fileURLWithPath: diskImagePath).lastPathComponent
        let attachedPath = file?.path(percentEncoded: false) ?? diskImagePath
        guard let session = instance.session else {
            Self.logger.log(
                .error,
                "Cannot attach USB device: no virtual machine for '\(instance.name, privacy: .public)'")
            throw RemovableMediaDeviceError.noVirtualMachine
        }
        guard session.hasUSBController else {
            Self.logger.log(
                .error,
                "Cannot attach USB device: no USB controller for '\(instance.name, privacy: .public)'")
            throw RemovableMediaDeviceError.noUSBController
        }

        let resolved: PathValidation.ResolvedPath
        do {
            resolved = try PathValidation.resolveFile(at: attachedPath, requireWritable: !readOnly)
            resolved.logResolution(logger: Self.logger, context: "USB disk image")
        } catch {
            let basename = URL(fileURLWithPath: attachedPath).lastPathComponent
            switch error {
            case .notFound:
                Self.logger.log(.error, "USB disk image not found: '\(basename, privacy: .public)'")
                throw RemovableMediaDeviceError.diskImageNotFound(attachedPath)
            case .unexpectedType:
                Self.logger.log(.error, "USB disk image path is a directory: '\(basename, privacy: .public)'")
                throw RemovableMediaDeviceError.diskImageIsDirectory(attachedPath)
            case .notWritable:
                Self.logger.log(.error, "USB disk image is not writable: '\(basename, privacy: .public)'")
                throw RemovableMediaDeviceError.diskImageNotWritable(attachedPath)
            case .notReadable:
                Self.logger.log(
                    .fault, "Unexpected .notReadable from resolveFile for '\(basename, privacy: .public)'")
                assertionFailure("resolveFile should never throw .notReadable")
                throw RemovableMediaDeviceError.diskImageNotFound(attachedPath)
            }
        }

        let url = resolved.url
        let uuid: UUID
        do {
            uuid = try await session.attachMassStorage(url: url, readOnly: readOnly, uuid: desiredUUID)
        } catch let error as VMSessionError {
            Self.logger.log(
                .error,
                "Cannot attach USB device '\(name, privacy: .public)' to VM '\(instance.name, privacy: .public)': \(String(describing: error), privacy: .public)"
            )
            throw RemovableMediaDeviceError.noUSBController
        } catch {
            Self.logger.log(
                .error,
                "Failed to attach USB device '\(name, privacy: .public)' to VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }

        let info = RemovableMediaDeviceInfo(id: uuid, path: diskImagePath, readOnly: readOnly)

        let source = url.lastPathComponent == name ? "" : " from '\(url.lastPathComponent)'"
        Self.logger.log(
            .notice,
            "Attached USB device '\(info.displayName, privacy: .public)'\(source, privacy: .public) to VM '\(instance.name, privacy: .public)' (readOnly: \(readOnly, privacy: .public))"
        )
        return info
    }

    package func detach(
        deviceInfo: RemovableMediaDeviceInfo,
        from instance: VMInstance
    ) async throws {
        guard let session = instance.session else {
            Self.logger.log(
                .error,
                "Cannot detach USB device: no virtual machine for '\(instance.name, privacy: .public)'")
            throw RemovableMediaDeviceError.noVirtualMachine
        }
        guard session.hasUSBController else {
            Self.logger.log(
                .error,
                "Cannot detach USB device: no USB controller for '\(instance.name, privacy: .public)'")
            throw RemovableMediaDeviceError.noUSBController
        }

        do {
            try await session.detachUSBDevice(uuid: deviceInfo.id)
        } catch VMSessionError.usbDeviceNotFound {
            Self.logger.log(
                .error,
                "USB device '\(deviceInfo.displayName, privacy: .public)' not found on controller for VM '\(instance.name, privacy: .public)'"
            )
            throw RemovableMediaDeviceError.deviceNotFound
        } catch VMSessionError.usbControllerUnavailable {
            throw RemovableMediaDeviceError.noUSBController
        } catch {
            Self.logger.log(
                .error,
                "Failed to detach USB device '\(deviceInfo.displayName, privacy: .public)' from VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }

        Self.logger.log(
            .notice,
            "Detached USB device '\(deviceInfo.displayName, privacy: .public)' from VM '\(instance.name, privacy: .public)'"
        )
    }
}
