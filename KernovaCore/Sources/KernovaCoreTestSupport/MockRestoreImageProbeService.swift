import Foundation

@testable import KernovaCore

/// Scripted stand-in for `RestoreImageProbing`: every probe answers a
/// well-formed Apple image.
@MainActor
final class MockRestoreImageProbeService: RestoreImageProbing {
    nonisolated init() {}

    func probe(_ url: URL) async throws -> ProbedRestoreImage {
        makeProbedImage()
    }

    func size(of url: URL) async throws -> UInt64 {
        19_772_077_142
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
