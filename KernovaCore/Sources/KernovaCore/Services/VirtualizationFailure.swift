import Foundation
import KernovaCommandModel

/// How a failure Virtualization reported is classified: which start failures
/// are transient, which are this copy's own file-lock contention, and what a
/// log line says about the chain beneath one.
package enum VirtualizationFailure {
    /// `VZErrorDomain` and the `VZErrorCode`s classified here, as
    /// `Virtualization/VZError.h` declares them.
    enum Framework {
        static let errorDomain = "VZErrorDomain"

        enum Code: Int {
            case invalidVirtualMachineConfiguration = 2
            case virtualMachineLimitExceeded = 6
            case operationCancelled = 9
        }
    }

    /// Detects VZ's advisory file-lock contention on a VM's backing files.
    ///
    /// Matches "Failed to lock auxiliary storage" (or the disk-image equivalent):
    /// `.invalidVirtualMachineConfiguration` carrying a POSIX `EAGAIN` underneath,
    /// which is what separates it from a genuinely invalid configuration (same VZ
    /// code, no `EAGAIN`) — matching localized text would be locale-fragile. A
    /// disk-image attach failure arrives wrapped in a `ConfigurationBuilderError`,
    /// so unwrap before matching or the contention retry never fires.
    package nonisolated static func isFileLockContention(_ error: Error) -> Bool {
        if let builderError = error as? ConfigurationBuilderError,
            let underlying = builderError.underlyingAttachError
        {
            return isFileLockContention(underlying)
        }
        let nsError = error as NSError
        guard nsError.domain == Framework.errorDomain,
            Framework.Code(rawValue: nsError.code) == .invalidVirtualMachineConfiguration,
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        else { return false }
        return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(EAGAIN)
    }

    /// How far an `NSUnderlyingErrorKey` walk follows the chain — framework
    /// `userInfo` can nest arbitrarily deep, or cyclically.
    nonisolated private static let maxUnderlyingErrorDepth = 4

    /// Returns `true` when the error is a transient environmental condition (e.g. too many
    /// concurrent VMs) rather than a problem with the VM itself.
    ///
    /// Transient leaves a plain start in `.stopped` and an install in
    /// `.initialBoot`, with no stored message; permanent rests at `.failed`
    /// (red) carrying the message for the banner and tooltip.
    nonisolated static func isTransientStartError(_ error: Error) -> Bool {
        // Checked ahead of the builder-error rule below: contention on a disk image
        // surfaces *as* a builder error and is still transient — the lock holder is
        // a dying VZVirtualMachine that releases it at deallocation.
        if isFileLockContention(error) { return true }

        if error is ConfigurationBuilderError { return false }

        if isVirtualMachineLimitExceeded(error) { return true }

        // Top level only, unlike the limit code: a cancel nested under a failure
        // describes a teardown step, not the failure that has to be classified.
        let nsError = error as NSError
        return nsError.domain == Framework.errorDomain
            && Framework.Code(rawValue: nsError.code) == .operationCancelled
    }

    /// Returns `true` when `error`, or anything within
    /// ``maxUnderlyingErrorDepth`` of its `NSUnderlyingErrorKey` chain, is
    /// `VZError.Code.virtualMachineLimitExceeded`.
    ///
    /// `VZMacOSInstaller.install()` surfaces the cap as `.installationFailed`
    /// carrying the real code underneath, so the top level alone identifies it
    /// on the plain-start path only.
    nonisolated static func isVirtualMachineLimitExceeded(_ error: Error) -> Bool {
        underlyingErrorChain(error as NSError).contains {
            $0.domain == Framework.errorDomain
                && Framework.Code(rawValue: $0.code) == .virtualMachineLimitExceeded
        }
    }

    /// `domain code` for each error *under* `error`, bounded by
    /// ``maxUnderlyingErrorDepth``; `"none"` when nothing is nested.
    package static func underlyingChainDescription(_ error: NSError) -> String {
        let nested = underlyingErrorChain(error).dropFirst()
        guard !nested.isEmpty else { return "none" }
        return nested.map { "\($0.domain) \($0.code)" }.joined(separator: " → ")
    }

    /// `error` followed by up to ``maxUnderlyingErrorDepth`` of its
    /// `NSUnderlyingErrorKey` ancestors.
    nonisolated private static func underlyingErrorChain(_ error: NSError) -> [NSError] {
        var chain: [NSError] = []
        var current: NSError? = error
        while let nsError = current, chain.count <= maxUnderlyingErrorDepth {
            chain.append(nsError)
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }

    /// `true` when `error` is a failed save-file restore — the one start/resume
    /// failure that rests at `.suspended` instead of `.error` or `.stopped`.
    package static func isRestoreFailure(_ error: Error) -> Bool {
        guard let virtualizationError = error as? VirtualizationError,
            case .restoreFailed = virtualizationError
        else { return false }
        return true
    }

    /// `error` with one `restoreFailed` wrapper peeled off, so the contention
    /// and transience classifiers can read the VZ failure underneath.
    package static func unwrappedRestoreFailure(_ error: Error) -> Error {
        guard let virtualizationError = error as? VirtualizationError,
            case .restoreFailed(let underlying, _) = virtualizationError
        else { return error }
        return underlying
    }
}

// MARK: - Errors

package enum VirtualizationError: LocalizedError {
    case invalidStateTransition(from: VMStatus, action: String)
    case noVirtualMachine
    case noSaveFile
    /// The file system turned the removal of the suspend slot down, so the VM
    /// is still resting on the session the discard was asked to end.
    case savedStateNotDiscarded
    /// `hostLocked` is whether this Mac's protected data was unavailable when
    /// the restore failed: the VM helper's Secure Enclave key is when-unlocked
    /// class (`docs/research/2026-09-30-vz-restore-matches-machine-shape-and-device-set.md`),
    /// so no restore succeeds until the Mac is unlocked.
    case restoreFailed(underlying: any Error, hostLocked: Bool = false)
    /// The revert wrote the snapshot back, and bringing the VM up on it failed.
    case revertResumeFailed(underlying: any Error)

    package var errorDescription: String? {
        switch self {
        case .invalidStateTransition(let status, let action):
            "Cannot \(action) VM in \(status.displayName) state."
        case .noVirtualMachine:
            "No virtual machine instance is available."
        case .noSaveFile:
            "No saved state file found."
        case .savedStateNotDiscarded:
            // The VM still holds the session, so it is still offered — nothing
            // was lost, and the same command is the way to try again.
            "The saved state could not be deleted."
        case .restoreFailed(let underlying, let hostLocked):
            // States what is known and stops. Nothing here can tell whether a
            // second attempt would fare better — after the device set has
            // diverged from the one the state was written with, none ever will
            // — and which commands the VM offers is its own state's answer.
            "Could not restore the saved state: \(underlying.localizedDescription)\n\n"
                + (hostLocked
                    ? "This Mac is locked, and a saved state can be restored only while it is unlocked. "
                    : "")
                + "The saved state was kept."
        case .revertResumeFailed(let underlying):
            "The virtual machine was reverted to the snapshot, but it could not be "
                + "resumed: \(underlying.localizedDescription)\n\n"
                + "The reverted state was kept — choose Resume to try again."
        }
    }
}

/// Bridges a wrapped underlying error into `NSUnderlyingErrorKey` so the
/// chain-walking classifiers (`isVirtualMachineLimitExceeded`,
/// `underlyingChainDescription`) see through the wrapper.
extension VirtualizationError: CustomNSError {
    package var errorUserInfo: [String: Any] {
        switch self {
        case .restoreFailed(let underlying, _), .revertResumeFailed(let underlying):
            [NSUnderlyingErrorKey: underlying as NSError]
        default:
            [:]
        }
    }
}
