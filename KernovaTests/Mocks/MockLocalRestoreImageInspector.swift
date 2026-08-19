import Foundation

@testable import Kernova

/// Scripted stand-in for `LocalRestoreImageInspecting`.
final class MockLocalRestoreImageInspector: LocalRestoreImageInspecting, @unchecked Sendable {
    var lastInspectedURL: URL?

    /// Thrown instead of returning, per the per-method `<method>Error` convention.
    var inspectError: (any Error)?
    /// Returned on success; defaults to a supported image.
    var inspectResult = InspectedRestoreImage(
        version: "15.6.1", build: "24G90", isSupportedOnThisHost: true)

    func inspect(_ url: URL) async throws -> InspectedRestoreImage {
        lastInspectedURL = url
        if let error = inspectError { throw error }
        return inspectResult
    }
}
