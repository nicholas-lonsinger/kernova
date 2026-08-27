import Foundation

/// What inspecting a restore image already on disk establishes: version, build,
/// and the supported-configuration verdict from Virtualization, plus the file's
/// size from the filesystem — Virtualization does not report it.
struct InspectedRestoreImage: Sendable, Equatable {
    /// Marketing version, e.g. `"15.6.1"`.
    var version: String
    /// Apple build identifier, e.g. `"24G90"`.
    var build: String
    /// Whether the framework offers a supported configuration for it on this host.
    var isSupportedOnThisHost: Bool
    /// The file's size on disk, or `nil` when it could not be read.
    var sizeBytes: UInt64?

    var summary: String { "macOS \(version) (\(build))" }
}

/// Why a restore image already on disk could not be adopted.
enum LocalRestoreImageError: LocalizedError, Equatable {
    case unreadable
    case unsupported

    var errorDescription: String? {
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
protocol LocalRestoreImageInspecting: Sendable {
    func inspect(_ url: URL) async throws -> InspectedRestoreImage
}
