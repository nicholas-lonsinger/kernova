import Foundation

/// The bundle-relative items a snapshot or a clone takes, and the copy that
/// moves them between bundles.
package enum VMBundleItems {
    // MARK: - Captured payload

    /// The bundle-relative paths a snapshot captures alongside the saved state.
    ///
    /// Every file the guest writes through that lives in the bundle: the disks
    /// it boots and stores data on, plus the firmware state VZ mutates
    /// (`AuxiliaryStorage` on macOS, `EFIVariableStore` on EFI Linux). The
    /// bundle's identity files (`HardwareModel`, `MachineIdentifier`) are
    /// absent — they never change, and a revert must not hand the VM a
    /// different identity.
    ///
    /// External disks are not captured: they are user-owned files outside the
    /// bundle, and copying them would double storage the user placed elsewhere
    /// on purpose.
    ///
    /// `layout` is the directory the firmware files are looked for in — the VM's
    /// bundle while capturing, the snapshot's own directory while working out
    /// what it holds.
    package static func capturedRelativePaths(
        for configuration: VMConfiguration, layout: VMBundleLayout
    ) -> [String] {
        let disks = configuration.effectiveStorageDisks(layout: layout)
        var paths = disks.filter(\.isInternal).map(\.path)
        for firmware in [
            VMBundleLayout.auxiliaryStorageRelativePath, VMBundleLayout.efiVariableStoreRelativePath,
            VMBundleLayout.guestAgentDiskRelativePath,
        ] {
            let url = layout.bundleURL.appendingPathComponent(firmware)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                paths.append(firmware)
            }
        }
        return paths
    }

    // MARK: - Copying between bundles

    /// What ``copyItems(_:from:to:ifMissing:)`` does about a path the source
    /// lacks.
    package enum MissingItem {
        /// Leaves it out of the copy.
        case skip
        /// Throws what the closure makes of the relative path.
        case fail((String) -> any Error)
        /// Copies without looking first, for a caller that already checked —
        /// the copy's own error reports a path gone since.
        case unchecked
    }

    /// Copies each file or directory `relativePaths` names from the root at
    /// `source` to the same relative path under `destination`, creating the
    /// parent directories it needs.
    package static func copyItems(
        _ relativePaths: [String], from source: URL, to destination: URL, ifMissing: MissingItem
    ) throws {
        let manager = FileManager.default
        for relativePath in relativePaths {
            let item = source.appendingPathComponent(relativePath)
            switch ifMissing {
            case .unchecked:
                break
            case .skip, .fail:
                guard !manager.fileExists(atPath: item.path(percentEncoded: false)) else { break }
                if case .fail(let error) = ifMissing { throw error(relativePath) }
                continue
            }
            let copy = destination.appendingPathComponent(relativePath)
            try manager.createDirectory(
                at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Same volume, so APFS clones each file rather than duplicating its
            // blocks — the copy shares them with the original until either
            // side writes.
            try manager.copyItem(at: item, to: copy)
        }
    }
}
