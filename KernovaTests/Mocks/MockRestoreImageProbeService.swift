import Foundation

@testable import Kernova

/// Scripted stand-in for `RestoreImageProbing`.
final class MockRestoreImageProbeService: RestoreImageProbing, @unchecked Sendable {
    var probeCallCount = 0
    var lastProbedURL: URL?

    /// Thrown instead of returning, per the per-method `<method>Error` convention.
    var probeError: (any Error)?
    /// Returned on success; defaults to a well-formed Apple image.
    var probeResult: ProbedRestoreImage = makeProbedImage()

    func probe(_ url: URL) async throws -> ProbedRestoreImage {
        probeCallCount += 1
        lastProbedURL = url
        if let error = probeError { throw error }
        return probeResult
    }
}

/// Builds a probed image, defaulted so a test names only what it cares about.
func makeProbedImage(
    urlString: String =
        "https://updates.cdn-apple.com/x/UniversalMac_15.6.1_24G90_Restore.ipsw",
    sizeBytes: UInt64 = 16_808_427_372,
    version: String? = "15.6.1",
    build: String? = "24G90"
) -> ProbedRestoreImage {
    ProbedRestoreImage(
        url: URL(string: urlString) ?? URL(fileURLWithPath: "/"),
        sizeBytes: sizeBytes,
        version: version,
        build: build
    )
}
