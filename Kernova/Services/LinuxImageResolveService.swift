import Foundation
import os

/// Resolves a Linux installer image source against its server, just before
/// downloading — and, for a user-supplied URL, once more in the wizard so the
/// pick is admitted before it is committed to.
///
/// For a catalog entry the manifest is the index: it is fetched, parsed,
/// matched against the entry's glob, and the newest match is the image — no
/// directory listing is scraped and no filename is guessed. What comes back
/// carries the mirror's own SHA-256, which is what the download is verified
/// against. A pasted URL names its file outright and carries only the digest
/// the user typed, so all that is read is the file's length.
///
/// A class rather than a struct so `deinit` can invalidate the `URLSession`, the
/// same reason `DownloadService` is one.
final class LinuxImageResolveService: LinuxImageResolving {
    private static let logger = Logger(
        subsystem: "app.kernova", category: "LinuxImageResolveService")

    /// The most of a checksum manifest that is read.
    ///
    /// The largest of these mirrors' manifests runs to a few kilobytes, so a
    /// body still arriving at a megabyte is not a manifest: it is an error page,
    /// a directory listing, or a mirror serving the wrong file. Reading stops
    /// there and the resolution fails rather than parsing on.
    private static let maximumManifestBytes = 1024 * 1024

    private let session: URLSession
    private let sizeProbe: RemoteFileSizeProbe

    init(sessionConfiguration: URLSessionConfiguration? = nil) {
        let configuration = sessionConfiguration ?? .ephemeral
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        self.session = session
        self.sizeProbe = RemoteFileSizeProbe(session: session)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    func resolve(_ entry: LinuxImageCatalogEntry) async throws -> ResolvedLinuxImage {
        // The entry reaching here came off a `config.json` a user can edit, so
        // it gets the catalog's own admission checks before it names a host to
        // contact or a file to read.
        guard entry.directoryURL.scheme?.lowercased() == "https" else {
            throw LinuxImageResolveError.insecureDirectory(url: entry.directoryURL)
        }
        guard LinuxImageCatalogService.isFilenameGlob(entry.isoPattern) else {
            throw LinuxImageResolveError.invalidISOPattern(pattern: entry.isoPattern)
        }
        guard LinuxImageCatalogService.isFilename(entry.checksumManifest) else {
            throw LinuxImageResolveError.invalidManifestName(manifest: entry.checksumManifest)
        }

        let manifestURL = entry.directoryURL.appendingPathComponent(entry.checksumManifest)
        let text = try await manifestText(at: manifestURL, named: entry.checksumManifest)
        let rows = ChecksumManifest.parse(text)
        guard !rows.isEmpty else {
            throw LinuxImageResolveError.manifestUnparseable(manifest: entry.checksumManifest)
        }

        let digests = Dictionary(
            rows.map { ($0.filename, $0.sha256) }, uniquingKeysWith: { first, _ in first })
        // The pattern is a wildcard `.iso` filename by the guard above, so a
        // glob that will not compile and a manifest listing nothing that
        // matches come to the same thing: no image to download.
        guard let glob = ISOFilenameGlob(entry.isoPattern),
            let filename = glob.newest(among: digests.keys),
            let sha256 = digests[filename]
        else {
            throw LinuxImageResolveError.noMatchingImage(pattern: entry.isoPattern)
        }
        guard let safeFilename = SafeFilename.sanitized(filename, requiring: "iso") else {
            throw LinuxImageResolveError.unusableFilename(filename)
        }

        let isoURL = entry.directoryURL.appendingPathComponent(safeFilename)
        let sizeBytes: UInt64
        do {
            sizeBytes = try await sizeProbe.size(of: isoURL)
        } catch {
            // A cancelled request fails as a transport error, and the caller
            // that cancelled has no error of its own to report.
            try Task.checkCancellation()
            Self.logger.error(
                "No size for '\(DownloadService.loggableURL(isoURL), privacy: .public)': \(String(describing: error), privacy: .public)"
            )
            throw LinuxImageResolveError.sizeUnavailable(filename: safeFilename)
        }

        Self.logger.notice(
            "Resolved \(entry.id, privacy: .public) to '\(safeFilename, privacy: .public)' (\(sizeBytes, privacy: .public) bytes)"
        )
        return ResolvedLinuxImage(
            isoURL: isoURL, filename: safeFilename, sha256: sha256, sizeBytes: sizeBytes)
    }

    func resolve(_ image: CustomLinuxImage) async throws -> ResolvedLinuxImage {
        let filename = try image.destinationFilename()
        let sizeBytes: UInt64
        do {
            sizeBytes = try await sizeProbe.size(of: image.url)
        } catch {
            // A cancelled request fails as a transport error, and the caller
            // that cancelled has no error of its own to report.
            try Task.checkCancellation()
            Self.logger.error(
                "No size for '\(DownloadService.loggableURL(image.url), privacy: .public)': \(String(describing: error), privacy: .public)"
            )
            throw (error as? RemoteFileSizeError).map(LinuxImageURLError.init)
                ?? .transportFailed(description: error.localizedDescription)
        }

        Self.logger.notice(
            "Checked the image at \(image.url.host() ?? "?", privacy: .public): '\(filename, privacy: .public)' (\(sizeBytes, privacy: .public) bytes, \(image.sha256 == nil ? "unverified" : "verified", privacy: .public))"
        )
        return ResolvedLinuxImage(
            isoURL: image.url, filename: filename, sha256: image.sha256, sizeBytes: sizeBytes)
    }

    // MARK: - HTTP

    /// The checksum manifest at `url`, read up to ``maximumManifestBytes``.
    ///
    /// Redirects are followed, which is how the fetch lands anywhere useful:
    /// Debian, Fedora and Kali answer even a manifest request with a redirect to
    /// a geographically close mirror, and Ubuntu serves it directly. The body is
    /// streamed rather than buffered whole so a mirror answering with something
    /// enormous is stopped at the cap instead of being read into memory.
    private func manifestText(at url: URL, named manifest: String) async throws -> String {
        let stream: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (stream, response) = try await session.bytes(from: url)
        } catch {
            try Task.checkCancellation()
            Self.logger.error(
                "Checksum manifest at '\(DownloadService.loggableURL(url), privacy: .public)' is unreachable: \(error.localizedDescription, privacy: .public)"
            )
            throw LinuxImageResolveError.manifestUnreachable(manifest: manifest, statusCode: nil)
        }
        guard let http = response as? HTTPURLResponse else {
            stream.task.cancel()
            throw LinuxImageResolveError.manifestUnreachable(manifest: manifest, statusCode: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            stream.task.cancel()
            throw LinuxImageResolveError.manifestUnreachable(
                manifest: manifest, statusCode: http.statusCode)
        }

        var body: [UInt8] = []
        do {
            for try await byte in stream {
                body.append(byte)
                if body.count > Self.maximumManifestBytes { break }
            }
        } catch {
            stream.task.cancel()
            try Task.checkCancellation()
            Self.logger.error(
                "Checksum manifest at '\(DownloadService.loggableURL(url), privacy: .public)' stopped mid-body: \(error.localizedDescription, privacy: .public)"
            )
            throw LinuxImageResolveError.manifestUnreachable(manifest: manifest, statusCode: nil)
        }
        stream.task.cancel()
        guard body.count <= Self.maximumManifestBytes else {
            Self.logger.error(
                "Checksum manifest \(manifest, privacy: .public) ran past \(Self.maximumManifestBytes, privacy: .public) bytes — not reading further"
            )
            throw LinuxImageResolveError.manifestTooLarge(manifest: manifest)
        }
        return String(decoding: body, as: UTF8.self)
    }
}
