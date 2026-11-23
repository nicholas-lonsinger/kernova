import Foundation

@testable import KernovaCore

/// Scripted stand-in for `LocalRestoreImageInspecting`.
@MainActor
final class MockLocalRestoreImageInspector: LocalRestoreImageInspecting {
    nonisolated init() {}

    /// Returned on every inspection; defaults to a supported image.
    var inspectResult = InspectedRestoreImage(
        version: "15.6.1", build: "24G90", isSupportedOnThisHost: true, sizeBytes: 15_500_000_000)

    func inspect(_ url: URL) async throws -> InspectedRestoreImage {
        inspectResult
    }
}
