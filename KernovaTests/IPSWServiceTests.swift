import Foundation
import Testing

@testable import Kernova

/// Covers what `IPSWService` still owns: forwarding the `IPSWProviding` surface
/// to the `DownloadService` it builds from the injected session and file system.
///
/// Every case here reaches the download service without issuing a request, so
/// this suite never touches `StubURLProtocol`'s global handler and can run
/// alongside `DownloadServiceTests`. `fetchLatestRestoreImage` is absent by
/// design — it is a direct `VZMacOSRestoreImage.latestSupported` call with no
/// injectable seam.
@Suite("IPSWService Tests", .admissionGated)
struct IPSWServiceTests {
    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPSWServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeService(fileSystem: any FileSystemOperating) -> IPSWService {
        IPSWService(sessionConfiguration: .ephemeral, fileSystem: fileSystem)
    }

    private static let remoteURL: URL = {
        guard let url = URL(string: "https://stub.kernova.test/RestoreImage.ipsw") else {
            assertionFailure("IPSWServiceTests: failed to construct the remote URL")
            return URL(filePath: "/")
        }
        return url
    }()

    @Test("downloadRestoreImage runs through the download service")
    func downloadRestoreImageDelegates() async throws {
        // An image already at the destination takes the download service's
        // skip-existing fast path, which reports the file it found without
        // issuing a request — so a completed call is proof the delegation is
        // wired, not that the network is reachable.
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")
        let preExisting = Data(repeating: 0x99, count: 2048)
        try preExisting.write(to: destination)

        let recorder = ProgressRecorder()
        let service = Self.makeService(fileSystem: MockFileSystem())
        try await service.downloadRestoreImage(
            from: Self.remoteURL,
            to: destination,
            progressHandler: { [recorder] progress in
                recorder.record(progress.bytesWritten)
            }
        )

        let samples = await recorder.snapshot()
        #expect(samples.last == Int64(preExisting.count))
    }

    @Test("downloadRestoreImage forwards discardsExistingDownload")
    func downloadRestoreImageForwardsDiscardsExistingDownload() async throws {
        // The replace-first step runs before any request, so a trash failure
        // surfaces as `DownloadError.freshDownloadCleanupFailed` — reachable
        // only if the flag made it through to the download service.
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")

        let fileSystem = MockFileSystem()
        fileSystem.trashError = CocoaError(.fileWriteNoPermission)
        let service = Self.makeService(fileSystem: fileSystem)

        await #expect(throws: DownloadError.self) {
            try await service.downloadRestoreImage(
                from: Self.remoteURL,
                to: destination,
                discardsExistingDownload: true,
                progressHandler: { _ in }
            )
        }
    }

    @Test("discardResumeData trashes the bundle beside the destination")
    func discardResumeDataTrashesBundle() throws {
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")

        let fileSystem = MockFileSystem()
        Self.makeService(fileSystem: fileSystem).discardResumeData(at: destination)

        #expect(fileSystem.trashedURLs == [DownloadService.resumeBundleURL(for: destination)])
        #expect(fileSystem.removedURLs.isEmpty)
    }

    @Test("discardResumeData bypasses the Trash when asked to delete immediately")
    func discardResumeDataPermanentlyRemovesBundle() throws {
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")

        let fileSystem = MockFileSystem()
        Self.makeService(fileSystem: fileSystem)
            .discardResumeData(at: destination, permanently: true)

        #expect(fileSystem.removedURLs == [DownloadService.resumeBundleURL(for: destination)])
        #expect(fileSystem.trashedURLs.isEmpty)
    }
}
