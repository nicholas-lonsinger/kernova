import Foundation

@testable import KernovaCore

/// Scripted stand-in for `IPSWProviding`.
@MainActor
final class MockIPSWService: IPSWProviding {
    nonisolated init() {}

    var fetchCallCount = 0
    var fetchError: (any Error)?

    /// Returned on success; defaults to a plausible newest release.
    var fetchResult = makeLatestImage()

    func fetchLatestRestoreImage() async throws -> LatestRestoreImage {
        fetchCallCount += 1
        if let error = fetchError { throw error }
        return fetchResult
    }
}

/// Builds the answer a latest-image lookup returns, defaulted so a test names
/// only what it cares about.
///
/// The default URL follows Apple's own convention, so the filename it derives
/// is the readable `UniversalMac_<version>_<build>_Restore.ipsw` rather than a
/// digest — pass `urlString` to exercise the off-convention path.
func makeLatestImage(
    version: String = "26.5.2",
    build: String = "25F84",
    urlString: String? = nil
) -> LatestRestoreImage {
    let resolved =
        urlString
        ?? "https://updates.cdn-apple.com/fullrestores/UniversalMac_\(version)_\(build)_Restore.ipsw"
    guard let url = URL(string: resolved) else {
        assertionFailure("makeLatestImage: could not build a URL from '\(resolved)'")
        return LatestRestoreImage(
            url: URL(fileURLWithPath: "/"), version: version, build: build)
    }
    return LatestRestoreImage(url: url, version: version, build: build)
}
