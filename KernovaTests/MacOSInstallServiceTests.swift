import Foundation
import Testing

@testable import Kernova

/// Covers the restore-image path resolution that precedes both Virtualization hand-offs.
///
/// `VZMacOSRestoreImage.load` and `VZMacOSInstaller.init` both take the
/// resolved URL. The install itself needs a real VZ stack and a multi-GB
/// IPSW, so it is exercised manually; this suite pins the seam that
/// regressed — VZ is only ever handed a symlink-free URL.
@MainActor
@Suite("MacOSInstallService Tests")
struct MacOSInstallServiceTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOSInstallServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The temp directory itself sits under a symlink (`/var` → `/private/var`),
        // so resolve the baseline to keep assertions about *our* symlinks honest.
        return dir.resolvingSymlinksInPath()
    }

    // MARK: - resolveRestoreImage

    @Test("resolveRestoreImage returns a real path unchanged")
    func resolveRestoreImageRealPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let image = dir.appendingPathComponent("RestoreImage.ipsw")
        FileManager.default.createFile(atPath: image.path(percentEncoded: false), contents: Data([0]))

        let resolved = try MacOSInstallService.resolveRestoreImage(at: image)
        #expect(resolved.path(percentEncoded: false) == image.path(percentEncoded: false))
    }

    /// The #558 regression: a symlinked *directory component* reaches the installer.
    ///
    /// The sandbox container's `Downloads` is a symlink to the real
    /// `~/Downloads`, so that is the shape the download destination arrives in.
    /// VZ reports such a path as nonexistent even though the file is there,
    /// which surfaced as an install failure immediately after a complete,
    /// valid download.
    @Test("resolveRestoreImage resolves a symlinked parent directory")
    func resolveRestoreImageSymlinkedParent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let realDir = dir.appendingPathComponent("RealDownloads")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let realImage = realDir.appendingPathComponent("RestoreImage.ipsw")
        FileManager.default.createFile(atPath: realImage.path(percentEncoded: false), contents: Data([0]))

        // Stand in for the container's `Downloads` symlink.
        let linkedDir = dir.appendingPathComponent("Downloads")
        try FileManager.default.createSymbolicLink(at: linkedDir, withDestinationURL: realDir)

        let viaSymlink = linkedDir.appendingPathComponent("RestoreImage.ipsw")
        let resolved = try MacOSInstallService.resolveRestoreImage(at: viaSymlink)

        #expect(resolved.path(percentEncoded: false) == realImage.path(percentEncoded: false))
    }

    @Test("resolveRestoreImage resolves a symlink to the image file itself")
    func resolveRestoreImageSymlinkedFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let realImage = dir.appendingPathComponent("Real.ipsw")
        FileManager.default.createFile(atPath: realImage.path(percentEncoded: false), contents: Data([0]))

        let link = dir.appendingPathComponent("Link.ipsw")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realImage)

        let resolved = try MacOSInstallService.resolveRestoreImage(at: link)
        #expect(resolved.path(percentEncoded: false) == realImage.path(percentEncoded: false))
    }

    @Test("resolveRestoreImage throws restoreImageNotFound for a missing file")
    func resolveRestoreImageMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let missing = dir.appendingPathComponent("Absent.ipsw")

        #expect {
            try MacOSInstallService.resolveRestoreImage(at: missing)
        } throws: { error in
            guard let error = error as? MacOSInstallError,
                case .restoreImageNotFound = error
            else { return false }
            return true
        }
    }

    /// A dangling symlink is the shape a moved/trashed image leaves behind —
    /// it must report "not found" rather than resolving to a phantom path that
    /// VZ would then reject with its own misleading wording.
    @Test("resolveRestoreImage throws restoreImageNotFound for a dangling symlink")
    func resolveRestoreImageDanglingSymlink() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let link = dir.appendingPathComponent("Dangling.ipsw")
        try FileManager.default.createSymbolicLink(
            atPath: link.path(percentEncoded: false),
            withDestinationPath: dir.appendingPathComponent("Gone.ipsw").path(percentEncoded: false)
        )

        #expect {
            try MacOSInstallService.resolveRestoreImage(at: link)
        } throws: { error in
            guard let error = error as? MacOSInstallError,
                case .restoreImageNotFound = error
            else { return false }
            return true
        }
    }

    /// The reported path reaches the user via `instance.errorMessage`, so it
    /// must name the resolved location rather than the sandbox container's
    /// `Downloads` spelling, which the user cannot act on.
    @Test("A missing image under a symlinked parent reports the resolved path")
    func resolveRestoreImageMissingReportsResolvedPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let realDir = dir.appendingPathComponent("RealDownloads")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)

        // Parent symlink is intact; the image itself is absent.
        let linkedDir = dir.appendingPathComponent("Downloads")
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
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let asDirectory = dir.appendingPathComponent("RestoreImage.ipsw")
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

    // MARK: - Error messages

    @Test("Restore image errors describe the offending path")
    func errorDescriptions() {
        #expect(
            MacOSInstallError.restoreImageNotFound(path: "/tmp/x.ipsw").errorDescription?
                .contains("/tmp/x.ipsw") == true
        )
        #expect(
            MacOSInstallError.restoreImageNotAFile(path: "/tmp/x.ipsw").errorDescription?
                .contains("/tmp/x.ipsw") == true
        )
    }
}
