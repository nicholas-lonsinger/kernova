import Foundation

/// A restore image already on disk, picked or adopted without a download.
struct LocalRestoreImage: Sendable, Equatable {
    var path: String
    var bookmark: Data?
    /// What inspecting the file established; `nil` while the inspection runs
    /// and after one that failed.
    var inspected: InspectedRestoreImage?
}
