import Foundation

/// What inspecting a restore image already on disk establishes: version, build,
/// and the supported-configuration verdict from Virtualization, plus the file's
/// size from the filesystem — Virtualization does not report it.
package struct InspectedRestoreImage: Sendable, Equatable {
    /// Marketing version, e.g. `"15.6.1"`.
    package var version: String
    /// Apple build identifier, e.g. `"24G90"`.
    package var build: String
    /// Whether the framework offers a supported configuration for it on this host.
    package var isSupportedOnThisHost: Bool
    /// The file's size on disk, or `nil` when it could not be read.
    package var sizeBytes: UInt64?

    package init(version: String, build: String, isSupportedOnThisHost: Bool, sizeBytes: UInt64? = nil) {
        self.version = version
        self.build = build
        self.isSupportedOnThisHost = isSupportedOnThisHost
        self.sizeBytes = sizeBytes
    }

    package var summary: String { "macOS \(version) (\(build))" }
}

/// Why a restore image already on disk could not be adopted.
package enum LocalRestoreImageError: LocalizedError, Equatable {
    case unreadable
    case unsupported

    package var errorDescription: String? {
        switch self {
        case .unreadable:
            "That file isn't a usable restore image."
        case .unsupported:
            "That restore image can't install into a virtual machine on this Mac."
        }
    }
}

/// Abstraction for reading a restore image that is already on disk.
///
/// Unlike a remote URL, a local file gets Virtualization's own answer:
/// `VZMacOSRestoreImage` loads from a file URL, so the version, build and
/// supported-configuration verdict here are the framework's, not a guess. The
/// size is read separately, off the same resolved URL, once the load succeeds.
package protocol LocalRestoreImageInspecting: Sendable {
    func inspect(_ url: URL) async throws -> InspectedRestoreImage
}
