import Foundation

@testable import Kernova

/// Scripted stand-in for `LinuxImageResolving`.
final class MockLinuxImageResolveService: LinuxImageResolving, @unchecked Sendable {
    var resolveCallCount = 0
    var lastResolvedEntry: LinuxImageCatalogEntry?

    /// Thrown instead of returning, per the per-method `<method>Error` convention.
    var resolveError: (any Error)?
    /// Returned on success; defaults to a well-formed Debian netinst image.
    var resolveResult: ResolvedLinuxImage = makeResolvedLinuxImage()

    func resolve(_ entry: LinuxImageCatalogEntry) async throws -> ResolvedLinuxImage {
        resolveCallCount += 1
        lastResolvedEntry = entry
        if let error = resolveError { throw error }
        return resolveResult
    }
}

/// Builds a resolved image, defaulted so a test names only what it cares about.
func makeResolvedLinuxImage(
    isoURLString: String =
        "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/debian-13.6.0-arm64-netinst.iso",
    filename: String = "debian-13.6.0-arm64-netinst.iso",
    sha256: String = "ffa590beb3ba6b1b0cf480a1f6a09ff3a05c4b0e0e0a24b9c2d3e5f708192a3b",
    sizeBytes: UInt64 = 735_358_976
) -> ResolvedLinuxImage {
    ResolvedLinuxImage(
        isoURL: URL(string: isoURLString) ?? URL(fileURLWithPath: "/"),
        filename: filename,
        sha256: sha256,
        sizeBytes: sizeBytes
    )
}
