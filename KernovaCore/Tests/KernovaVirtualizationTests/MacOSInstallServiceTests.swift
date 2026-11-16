import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaVirtualization
@testable import KernovaVirtualizationTestSupport

/// Covers the restore-image path resolution that precedes both Virtualization hand-offs.
///
/// `VZMacOSRestoreImage.load` and `VZMacOSInstaller.init` both take the
/// resolved URL. The install itself needs a real VZ stack and a multi-GB
/// IPSW, so it is exercised manually; this suite pins the seam that
/// regressed — VZ is only ever handed a symlink-free URL.
@MainActor
@Suite("MacOSInstallService Tests", .caseScoped)
struct MacOSInstallServiceTests {
    private let scratch = TestScratchDirectory(prefix: "MacOSInstallServiceTests")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    // MARK: - resolveRestoreImage

    /// The #558 regression: a symlinked *directory component* reaches the installer.
    ///
    /// The sandbox container's `Downloads` is a symlink to the real
    /// `~/Downloads`, so that is the shape the download destination arrives in.
    /// VZ reports such a path as nonexistent even though the file is there,
    /// which surfaced as an install failure immediately after a complete,
    /// valid download.
    @Test("resolveRestoreImage resolves a symlinked parent directory")
    func resolveRestoreImageSymlinkedParent() throws {
        let realDir = scratch.url.appendingPathComponent("RealDownloads")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let realImage = realDir.appendingPathComponent("RestoreImage.ipsw")
        FileManager.default.createFile(atPath: realImage.path(percentEncoded: false), contents: Data([0]))

        // Stand in for the container's `Downloads` symlink.
        let linkedDir = scratch.url.appendingPathComponent("Downloads")
        try FileManager.default.createSymbolicLink(at: linkedDir, withDestinationURL: realDir)

        let viaSymlink = linkedDir.appendingPathComponent("RestoreImage.ipsw")
        let resolved = try MacOSInstallService.resolveRestoreImage(at: viaSymlink)

        #expect(resolved.path(percentEncoded: false) == realImage.path(percentEncoded: false))
    }

    /// The reported path reaches the user via `instance.errorMessage`, so it
    /// must name the resolved location rather than the sandbox container's
    /// `Downloads` spelling, which the user cannot act on.
    @Test("A missing image under a symlinked parent reports the resolved path")
    func resolveRestoreImageMissingReportsResolvedPath() throws {
        let realDir = scratch.url.appendingPathComponent("RealDownloads")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)

        // Parent symlink is intact; the image itself is absent.
        let linkedDir = scratch.url.appendingPathComponent("Downloads")
        try FileManager.default.createSymbolicLink(at: linkedDir, withDestinationURL: realDir)

        let missing = linkedDir.appendingPathComponent("RestoreImage.ipsw")
        let expected = realDir.appendingPathComponent("RestoreImage.ipsw")
            .path(percentEncoded: false)

        #expect {
            try MacOSInstallService.resolveRestoreImage(at: missing)
        } throws: { error in
            guard let error = error as? MacOSInstallError,
                case .restoreImageNotFound(let path) = error
            else { return false }
            return path == expected
        }
    }

    @Test("resolveRestoreImage throws restoreImageNotAFile for a directory")
    func resolveRestoreImageDirectory() throws {
        let asDirectory = scratch.url.appendingPathComponent("RestoreImage.ipsw")
        try FileManager.default.createDirectory(at: asDirectory, withIntermediateDirectories: true)

        #expect {
            try MacOSInstallService.resolveRestoreImage(at: asDirectory)
        } throws: { error in
            guard let error = error as? MacOSInstallError,
                case .restoreImageNotAFile = error
            else { return false }
            return true
        }
    }
}
