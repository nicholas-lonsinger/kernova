import Foundation

// MARK: - Errors

enum ConfigurationBuilderError: LocalizedError {
    case invalidHardwareModel
    case invalidMachineIdentifier
    /// An EFI boot found no variable store in the bundle.
    case efiVariableStoreMissing
    case missingKernelPath
    case kernelNotFound(String)
    case kernelPathIsDirectory(String)
    case initrdNotFound(String)
    case initrdPathIsDirectory(String)
    // Every failure naming one attachment carries that entry's `id`, so a
    // bring-up can offer to remove the entry it named
    // (``VMCommandCore/bringUpFailedAttachment(from:verb:on:)``) whichever way
    // the attachment turned out to be unusable.
    case storageDiskNotFound(id: UUID, path: String, label: String)
    case storageDiskPathIsDirectory(id: UUID, path: String, label: String)
    case storageDiskNotWritable(id: UUID, path: String, label: String)
    /// The disk file exists but `VZDiskImageStorageDeviceAttachment` refused it —
    /// commonly the sandbox denying `open` on a path the app no longer holds a
    /// grant for (surfaced as "Operation not supported"), or an invalid image.
    ///
    /// `underlying` must be preserved verbatim, not flattened to a string: the
    /// start path classifies transient file-lock contention off its NSError
    /// domain/code, so discarding it turns a retryable boot into a hard failure.
    case storageDiskAttachFailed(id: UUID, path: String, label: String, underlying: any Error)
    case removableMediaNotFound(id: UUID, path: String, label: String)
    case removableMediaPathIsDirectory(id: UUID, path: String, label: String)
    case removableMediaNotWritable(id: UUID, path: String, label: String)
    /// Removable-media counterpart of `storageDiskAttachFailed`.
    case removableMediaAttachFailed(id: UUID, path: String, label: String, underlying: any Error)
    /// The configuration is on a network this build cannot attach
    /// (``EntitlementService/canAttach(_:)``).
    case networkNotEntitled(VMJoinedNetwork)
    case sharedDirectoryNotFound(id: UUID, path: String, label: String)
    case sharedDirectoryNotADirectory(id: UUID, path: String, label: String)
    case sharedDirectoryNotReadable(id: UUID, path: String, label: String)
    case sharedDirectoryNotWritable(id: UUID, path: String, label: String)

    var errorDescription: String? {
        switch self {
        case .invalidHardwareModel:
            "The stored hardware model data is invalid."
        case .invalidMachineIdentifier:
            "The stored machine identifier data is invalid."
        case .efiVariableStoreMissing:
            "The virtual machine's EFI variable store is missing."
        case .missingKernelPath:
            "A kernel path is required for Linux kernel boot mode."
        case .kernelNotFound(let path):
            "Kernel image not found at \(path)."
        case .kernelPathIsDirectory(let path):
            "Kernel path is a directory, not a file: \(path)."
        case .initrdNotFound(let path):
            "Initial ramdisk not found at \(path)."
        case .initrdPathIsDirectory(let path):
            "Initial ramdisk path is a directory, not a file: \(path)."
        case .storageDiskNotFound(_, let path, let label):
            "Storage disk '\(label)' not found at \(path)."
        case .storageDiskPathIsDirectory(_, let path, let label):
            "Storage disk '\(label)' path is a directory, not a file: \(path)."
        case .storageDiskNotWritable(_, let path, let label):
            "Storage disk '\(label)' is not writable: \(path)."
        case .storageDiskAttachFailed(_, let path, let label, let underlying):
            "Couldn't open storage disk '\(label)' at \(path). The file may have been moved or replaced, or Kernova may no longer have permission to read it. (\(underlying.localizedDescription))"
        case .removableMediaNotFound(_, let path, let label):
            "Removable media '\(label)' not found at \(path)."
        case .removableMediaPathIsDirectory(_, let path, let label):
            "Removable media '\(label)' path is a directory, not a file: \(path)."
        case .removableMediaNotWritable(_, let path, let label):
            "Removable media '\(label)' is not writable: \(path)."
        case .removableMediaAttachFailed(_, let path, let label, let underlying):
            "Couldn't open removable media '\(label)' at \(path). The file may have been moved or replaced, or Kernova may no longer have permission to read it. (\(underlying.localizedDescription))"
        case .networkNotEntitled(let network):
            "This build of Kernova does not support \(network.entitledCapability). "
                + (network.isCommon
                    ? "Switch the VM's network mode to \(VMNetworkMode.nat.title)."
                    : "Move the VM to its mode\u{2019}s common network in its Network settings.")
        case .sharedDirectoryNotFound(_, let path, let label):
            "Shared folder '\(label)' not found at \(path)."
        case .sharedDirectoryNotADirectory(_, let path, let label):
            "Shared item '\(label)' is not a folder: \(path)."
        case .sharedDirectoryNotReadable(_, let path, let label):
            "Shared folder '\(label)' is not readable: \(path)."
        case .sharedDirectoryNotWritable(_, let path, let label):
            "Shared folder '\(label)' is not writable: \(path)."
        }
    }

    /// What was wrong with the one attachment this names, or `nil` for a
    /// failure that names none.
    ///
    /// The whole of the case analysis the bring-up's recovery needs, so a new
    /// per-attachment case is answered here rather than falling silently
    /// through to the bare alert.
    var attachmentReason: StartFailedAttachment.Reason? {
        switch self {
        case .storageDiskNotFound, .removableMediaNotFound, .sharedDirectoryNotFound: .notFound
        case .storageDiskPathIsDirectory, .removableMediaPathIsDirectory: .pathIsDirectory
        case .sharedDirectoryNotADirectory: .notADirectory
        case .sharedDirectoryNotReadable: .notReadable
        case .storageDiskNotWritable, .removableMediaNotWritable, .sharedDirectoryNotWritable:
            .notWritable
        case .storageDiskAttachFailed, .removableMediaAttachFailed: .attachRefused
        case .invalidHardwareModel, .invalidMachineIdentifier, .efiVariableStoreMissing,
            .missingKernelPath,
            .kernelNotFound, .kernelPathIsDirectory, .initrdNotFound, .initrdPathIsDirectory,
            .networkNotEntitled:
            nil
        }
    }

    /// The framework error behind an attach failure, or `nil` for every other case.
    var underlyingAttachError: (any Error)? {
        switch self {
        case .storageDiskAttachFailed(_, _, _, let underlying),
            .removableMediaAttachFailed(_, _, _, let underlying):
            underlying
        default:
            nil
        }
    }
}
