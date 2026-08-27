import Foundation

/// The state of inspecting a ``LocalRestoreImage``: running, or the verdict it
/// reached.
enum LocalRestoreImageInspection: Sendable, Equatable {
    case pending
    case usable(InspectedRestoreImage)
    case unusable(LocalRestoreImageError)

    /// The image's own metadata, when it is one this Mac can install.
    var usable: InspectedRestoreImage? {
        if case .usable(let inspected) = self { return inspected }
        return nil
    }
}

/// A restore image already on disk, picked or adopted without a download.
struct LocalRestoreImage: Sendable, Equatable {
    var path: String
    var bookmark: Data?
    /// What inspecting the file established.
    var inspection: LocalRestoreImageInspection = .pending
}
