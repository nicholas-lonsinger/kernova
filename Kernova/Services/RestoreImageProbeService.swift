import Foundation
import os

/// Checks a user-supplied restore image URL before anything is downloaded.
///
/// A class rather than a struct so `deinit` can invalidate the `URLSession`, the
/// same reason `IPSWService` is one.
final class RestoreImageProbeService: RestoreImageProbing {
    private static let logger = Logger(
        subsystem: "app.kernova", category: "RestoreImageProbeService")

    /// How much of the file's tail to read looking for the zip end-of-directory record.
    ///
    /// Comfortably larger than the record plus a maximal comment.
    private static let tailWindow: Int64 = 131_072

    private let session: URLSession

    init(sessionConfiguration: URLSessionConfiguration? = nil) {
        let configuration = sessionConfiguration ?? .ephemeral
        configuration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    func probe(_ url: URL) async throws -> ProbedRestoreImage {
        guard url.scheme?.lowercased() == "https" else {
            throw RestoreImageProbeError.insecureURL
        }

        let sizeBytes = try await totalSize(of: url)
        guard sizeBytes > 0 else { throw RestoreImageProbeError.unknownSize }

        switch try await supportsVirtualMachine(url, totalBytes: Int64(sizeBytes)) {
        case .some(true):
            break
        case .some(false):
            throw RestoreImageProbeError.notAVirtualMachineImage
        case .none:
            throw RestoreImageProbeError.unreadableStructure
        }

        let parsed = ProbedRestoreImage.parseFilename(url.lastPathComponent)
        Self.logger.notice(
            "Probed restore image at \(url.host() ?? "?", privacy: .public): \(sizeBytes, privacy: .public) bytes, VM-capable"
        )
        return ProbedRestoreImage(
            url: url, sizeBytes: sizeBytes, version: parsed.version, build: parsed.build)
    }

    // MARK: - HTTP

    /// The file's length in bytes.
    ///
    /// Read from `HEAD` where the server answers it, and from a one-byte ranged
    /// `GET`'s `Content-Range` where it does not.
    private func totalSize(of url: URL) async throws -> UInt64 {
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        if let response = try await status(for: head) {
            guard (200..<300).contains(response.statusCode) else {
                throw RestoreImageProbeError.unreachable(statusCode: response.statusCode)
            }
            if response.expectedContentLength > 0 {
                return UInt64(response.expectedContentLength)
            }
        }

        var probe = URLRequest(url: url)
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let response = try await status(for: probe) else {
            throw RestoreImageProbeError.unknownSize
        }
        guard (200..<300).contains(response.statusCode) else {
            throw RestoreImageProbeError.unreachable(statusCode: response.statusCode)
        }
        // `Content-Range: bytes 0-0/19772077142` — the total is after the slash.
        if let range = response.value(forHTTPHeaderField: "Content-Range"),
            let total = range.split(separator: "/").last,
            let bytes = UInt64(total.trimmingCharacters(in: .whitespaces))
        {
            return bytes
        }
        throw RestoreImageProbeError.unknownSize
    }

    private func status(for request: URLRequest) async throws -> HTTPURLResponse? {
        do {
            let (_, response) = try await session.data(for: request)
            return response as? HTTPURLResponse
        } catch let error as URLError {
            throw RestoreImageProbeError.transportFailed(
                description: error.localizedDescription)
        }
    }

    /// Fetches a byte range, or `nil` when the server would not serve one.
    private func range(_ url: URL, from offset: Int64, count: Int64) async -> [UInt8]? {
        guard count > 0, offset >= 0 else { return nil }
        var request = URLRequest(url: url)
        request.setValue(
            "bytes=\(offset)-\(offset + count - 1)", forHTTPHeaderField: "Range")
        guard let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse,
            http.statusCode == 206 || http.statusCode == 200
        else { return nil }
        return [UInt8](data)
    }

    // MARK: - Zip directory

    /// Whether a restore image contains the virtual-machine hardware model.
    ///
    /// An IPSW is a zip. Its central directory lists `kernelcache.release.vma2`
    /// and `apticket.vma2macosap.im4m` exactly when the image can install into a
    /// VM, so reading the directory alone settles it — three ranged requests and
    /// roughly 150 KB rather than the whole multi-gigabyte file. This is the same
    /// check `Tools/regen-restore-image-catalog.swift` applies to every catalog
    /// candidate, which is what makes a pasted URL as trustworthy as a catalog row.
    ///
    /// `nil` means the structure could not be read, which is not the same as a "no".
    private func supportsVirtualMachine(_ url: URL, totalBytes: Int64) async throws -> Bool? {
        let tailStart = max(0, totalBytes - Self.tailWindow)
        guard let tail = await range(url, from: tailStart, count: totalBytes - tailStart),
            let eocd = Self.lastIndex(of: [0x50, 0x4B, 0x05, 0x06], in: tail),
            var directorySize = Self.readLE(tail, eocd + 12, UInt32.self).map(Int64.init),
            var directoryOffset = Self.readLE(tail, eocd + 16, UInt32.self).map(Int64.init)
        else { return nil }

        // Restore images exceed 4 GB, so the real offsets live in the zip64
        // record the locator points at; the 32-bit fields above are sentinels.
        if let locator = Self.lastIndex(of: [0x50, 0x4B, 0x06, 0x07], in: tail),
            let zip64Offset = Self.readLE(tail, locator + 8, UInt64.self),
            let header = await range(url, from: Int64(zip64Offset), count: 64),
            Array(header.prefix(4)) == [0x50, 0x4B, 0x06, 0x06],
            let size = Self.readLE(header, 40, UInt64.self),
            let offset = Self.readLE(header, 48, UInt64.self)
        {
            directorySize = Int64(size)
            directoryOffset = Int64(offset)
        }

        guard directorySize > 0, directoryOffset >= 0,
            let directory = await range(url, from: directoryOffset, count: directorySize)
        else { return nil }
        return Self.lastIndex(of: [UInt8]("vma2".utf8), in: directory) != nil
    }

    static func readLE<T: FixedWidthInteger>(_ bytes: [UInt8], _ offset: Int, _ type: T.Type) -> T? {
        let width = MemoryLayout<T>.size
        guard offset >= 0, offset + width <= bytes.count else { return nil }
        var value: T = 0
        for index in (0..<width).reversed() { value = (value << 8) | T(bytes[offset + index]) }
        return value
    }

    static func lastIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count, !needle.isEmpty else { return nil }
        for start in stride(from: haystack.count - needle.count, through: 0, by: -1)
        where Array(haystack[start..<start + needle.count]) == needle {
            return start
        }
        return nil
    }
}
