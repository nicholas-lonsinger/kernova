import Foundation

/// The bundle-relative items a snapshot or a clone takes, the copy that
/// moves them between bundles, and the walk that finds a symbolic link in
/// one — a bundle holds real files and directories only.
package enum VMBundleItems {
    // MARK: - Captured payload

    /// The bundle-relative paths a snapshot captures alongside the saved state.
    ///
    /// Every bundle file the saved state restores onto: the disks the guest
    /// boots and stores data on, the firmware state VZ mutates
    /// (`AuxiliaryStorage` on macOS, `EFIVariableStore` on EFI Linux), and the
    /// VM's copies of the guest-agent installer disks (`GuestAgentDisk`). The
    /// bundle's identity files (`HardwareModel`, `MachineIdentifier`) are
    /// absent — they never change, and a revert must not hand the VM a
    /// different identity.
    ///
    /// External disks are not captured: they are user-owned files outside the
    /// bundle, and copying them would double storage the user placed elsewhere
    /// on purpose.
    ///
    /// `layout` is the directory the firmware files and installer copies are looked for in — the VM's
    /// bundle while capturing, the snapshot's own directory while working out
    /// what it holds.
    package static func capturedRelativePaths(
        for configuration: VMConfiguration, layout: VMBundleLayout
    ) -> [String] {
        let disks = configuration.effectiveStorageDisks(layout: layout)
        var paths = disks.filter(\.isInternal).map(\.path)
        for item in [
            VMBundleLayout.auxiliaryStorageRelativePath, VMBundleLayout.efiVariableStoreRelativePath,
            VMBundleLayout.guestAgentDiskRelativePath,
        ] {
            let url = layout.bundleURL.appendingPathComponent(item)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                paths.append(item)
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
    /// parent directories it needs. Each is copied as ``copy(_:to:)`` copies.
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
                // Asked of the item itself, so a link whose target is gone is
                // there, and the copy refuses it as any other link.
                guard (try? manager.attributesOfItem(atPath: item.path(percentEncoded: false))) == nil else {
                    break
                }
                if case .fail(let error) = ifMissing { throw error(relativePath) }
                continue
            }
            let target = destination.appendingPathComponent(relativePath)
            try manager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try copy(item, to: target)
        }
    }

    /// Copies the file or directory tree at `source` to `destination`, which
    /// must not exist.
    ///
    /// A bundle holds real files and directories only, so a symbolic link
    /// anywhere in the tree, `source` included, fails the copy with a
    /// ``SymbolicLinkError`` naming it: a copied link would share its target
    /// with the source.
    package static func copy(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        switch try item(at: source) {
        case .link:
            throw SymbolicLinkError(url: source)
        case .file:
            // On one APFS volume this clones the file rather than duplicating
            // its blocks — the copy shares them with the original until either
            // side writes.
            try manager.copyItem(at: source, to: destination)
            return
        case .directory:
            break
        }
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)
        let sourcePath = source.path(percentEncoded: false)
        for name in try manager.contentsOfDirectory(atPath: sourcePath) {
            try copy(source.appendingPathComponent(name), to: destination.appendingPathComponent(name))
        }
        // After the contents, so a source directory that denies writing still
        // copies whole.
        let copied = copyfile(
            sourcePath, destination.path(percentEncoded: false), nil, copyfile_flags_t(COPYFILE_METADATA))
        guard copied == 0 else { throw fileError(errno, at: destination) }
    }

    // MARK: - Symbolic links

    /// The first symbolic link anywhere below `root`, as the error that
    /// refuses it, or `nil` when the tree holds none. `root` itself, and
    /// every directory above it, may be a link: the walk starts from what
    /// `root` resolves to, and follows nothing below it.
    ///
    /// A directory or item that can't be read is passed over: the walk names
    /// only a link it can see.
    package static func symbolicLink(below root: URL) -> SymbolicLinkError? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        for name in names.sorted() {
            let url = root.appendingPathComponent(name)
            switch try? item(at: url) {
            case .link: return SymbolicLinkError(url: url)
            case .directory: if let link = symbolicLink(below: url) { return link }
            case .file, nil: continue
            }
        }
        return nil
    }

    /// What a walk of a bundle tree meets at a path.
    private enum Item {
        case file, directory, link
    }

    /// What `url` is, read from the item itself: a link is a link, whatever
    /// it points at — the one test ``copy(_:to:)`` and
    /// ``symbolicLink(below:)`` share, so what one refuses the other finds.
    private static func item(at url: URL) throws -> Item {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        if values.isSymbolicLink == true { return .link }
        return values.isDirectory == true ? .directory : .file
    }

    /// A symbolic link where a bundle's own file or directory belongs.
    package struct SymbolicLinkError: LocalizedError, CustomNSError, Equatable {
        package let url: URL

        /// Why the link is refused, worded to follow the name of the item it
        /// is said of ("“Disk.asif” is a symbolic link, and …").
        package static let reason =
            "is a symbolic link, and Kernova supports only real files and folders inside a virtual machine"

        /// ``reason`` as the cause of a failure a sentence has just named the
        /// item in ("… could not be copied: It is a symbolic link, and …").
        package static let cause = "It \(reason)"

        package static let errorDomain = "app.kernova.VMBundleItems.SymbolicLink"

        package var errorUserInfo: [String: Any] {
            [NSFilePathErrorKey: url.path(percentEncoded: false)]
        }

        package var errorDescription: String? {
            "\u{201C}\(url.lastPathComponent)\u{201D} could not be copied: \(Self.cause)."
        }

        /// The sentence stating the link, named by its path below `root` — the
        /// directory ``VMBundleItems/symbolicLink(below:)`` walked.
        package func statement(below root: URL) -> String {
            let name = url.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
            return "\u{201C}\(name)\u{201D} \(Self.reason)."
        }
    }

    /// A file error naming `url`, over the POSIX error `code`.
    package static func fileError(_ code: Int32, at url: URL) -> CocoaError {
        CocoaError(
            .fileReadUnknown,
            userInfo: [
                NSFilePathErrorKey: url.path(percentEncoded: false),
                NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) as NSError,
            ])
    }
}
