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

    /// How much of the zip64 end-of-directory record to read.
    ///
    /// Its fixed fields end at 56 bytes, and the two the probe wants — the
    /// central directory's size and offset — are the last of them.
    private static let zip64RecordWindow: Int64 = 64

    /// The most any one ranged read pulls into memory.
    ///
    /// The tail and the zip64 record are fixed and small, so this bounds the one
    /// read whose length the remote file dictates: a zip64 record can claim a
    /// central directory of any size, while a real IPSW's runs to a few hundred
    /// kilobytes.
    private static let maxRangeBytes: Int64 = 16 * 1024 * 1024

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
        // `size(of:)` owns the HTTPS-only refusal and the non-zero floor.
        let sizeBytes = try await size(of: url)
        guard let totalBytes = Int64(exactly: sizeBytes) else {
            throw RestoreImageProbeError.unknownSize
        }

        switch try await supportsVirtualMachine(url, totalBytes: totalBytes) {
        case .some(true):
            break
        case .some(false):
            throw RestoreImageProbeError.notAVirtualMachineImage
        case .none:
            throw RestoreImageProbeError.unreadableStructure
        }

        let parsed = ProbedRestoreImage.parseFilename(url.lastPathComponent)
        Self.logger.info(
            "Probed restore image at \(url.host() ?? "?", privacy: .public): \(sizeBytes, privacy: .public) bytes, VM-capable"
        )
        return ProbedRestoreImage(
            url: url, sizeBytes: sizeBytes, version: parsed.version, build: parsed.build)
    }

    // MARK: - HTTP

    /// The file's length in bytes.
    ///
    /// `HEAD` answers it wherever a server implements it. A server that refuses
    /// `HEAD` — pre-signed S3 and CloudFront links answer 403, others 405 — still
    /// serves the ranged `GET`s the rest of the probe is built from, so a
    /// non-2xx `HEAD` is not fatal: the one-byte ranged `GET`'s `Content-Range`
    /// settles the size, and its status settles whether the URL is live at all.
    func size(of url: URL) async throws -> UInt64 {
        guard url.scheme?.lowercased() == "https" else {
            throw RestoreImageProbeError.insecureURL
        }

        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        if let response = try await responseWithoutBody(for: head),
            (200..<300).contains(response.statusCode),
            response.expectedContentLength > 0
        {
            return UInt64(response.expectedContentLength)
        }

        var probe = URLRequest(url: url)
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let response = try await responseWithoutBody(for: probe) else {
            throw RestoreImageProbeError.unknownSize
        }
        guard response.statusCode == 206 else {
            // 2xx that isn't 206 means the Range header was ignored and the body
            // is the whole file, which is neither a size nor something to read.
            guard (200..<300).contains(response.statusCode) else {
                throw RestoreImageProbeError.unreachable(statusCode: response.statusCode)
            }
            throw RestoreImageProbeError.rangeRequestsUnsupported
        }
        // `Content-Range: bytes 0-0/19772077142` — the total is after the slash.
        // A stated zero is refused here rather than returned: callers format the
        // result as a download size, and `bytes 0-0/0` is a server that does not
        // know the length, not a file with no bytes.
        guard let range = response.value(forHTTPHeaderField: "Content-Range"),
            let total = range.split(separator: "/").last,
            let bytes = UInt64(total.trimmingCharacters(in: .whitespaces)),
            bytes > 0
        else {
            throw RestoreImageProbeError.unknownSize
        }
        return bytes
    }

    /// The response to `request`, with its body abandoned unread.
    ///
    /// `URLSession.bytes(for:)` surfaces the response as the body starts
    /// arriving and streams the rest under backpressure, so cancelling here
    /// costs one read-ahead buffer. `data(for:)` in its place buffers a server's
    /// entire multi-gigabyte answer to a ranged request before the status can be
    /// looked at. `nil` means the response was not HTTP.
    private func responseWithoutBody(for request: URLRequest) async throws -> HTTPURLResponse? {
        do {
            let (stream, response) = try await session.bytes(for: request)
            stream.task.cancel()
            return response as? HTTPURLResponse
        } catch let error as URLError {
            throw RestoreImageProbeError.transportFailed(
                description: error.localizedDescription)
        }
    }

    /// Fetches a byte range, or `nil` when the server would not serve that one.
    ///
    /// Only 206 is accepted: a 200 means the server ignored the `Range` header
    /// and is sending the entire file, so the response is abandoned rather than
    /// read. The body is streamed and stopped at `count` bytes, which is what
    /// keeps a mis-sized or hostile length from becoming an unbounded read.
    private func range(_ url: URL, from offset: Int64, count: Int64) async throws -> [UInt8]? {
        guard offset >= 0, count > 0, count <= Self.maxRangeBytes,
            let limit = Int(exactly: count)
        else { return nil }
        let (last, overflowed) = offset.addingReportingOverflow(count - 1)
        guard !overflowed else { return nil }

        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(last)", forHTTPHeaderField: "Range")
        guard let (stream, response) = try? await session.bytes(for: request) else { return nil }
        guard let http = response as? HTTPURLResponse else {
            stream.task.cancel()
            return nil
        }
        guard http.statusCode == 206 else {
            stream.task.cancel()
            // 2xx that isn't 206 means the Range header was ignored and the body
            // is the whole file, so no read here can ever be satisfied.
            guard (200..<300).contains(http.statusCode) else { return nil }
            throw RestoreImageProbeError.rangeRequestsUnsupported
        }

        var buffer: [UInt8] = []
        do {
            for try await byte in stream {
                buffer.append(byte)
                if buffer.count == limit { break }
            }
        } catch {
            stream.task.cancel()
            return nil
        }
        stream.task.cancel()
        return buffer
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
        guard let tail = try await range(url, from: tailStart, count: totalBytes - tailStart),
            let eocd = Self.lastIndex(of: [0x50, 0x4B, 0x05, 0x06], in: tail),
            var directorySize = Self.readLE(tail, eocd + 12, UInt32.self).map(Int64.init),
            var directoryOffset = Self.readLE(tail, eocd + 16, UInt32.self).map(Int64.init)
        else { return nil }

        // Restore images exceed 4 GB, so where a locator is present the real
        // offsets live in the zip64 record it points at and the 32-bit fields
        // above are sentinels — an unusable record is unreadable structure, not
        // a reason to trust the sentinels.
        if let locator = Self.lastIndex(of: [0x50, 0x4B, 0x06, 0x07], in: tail) {
            guard
                let bounds = try await zip64DirectoryBounds(
                    url, tail: tail, locator: locator, totalBytes: totalBytes)
            else { return nil }
            directoryOffset = bounds.offset
            directorySize = bounds.size
        }

        guard Self.fits(offset: directoryOffset, count: directorySize, within: totalBytes),
            let directory = try await range(
                url, from: directoryOffset, count: min(directorySize, Self.maxRangeBytes))
        else { return nil }
        return Self.lastIndex(of: [UInt8]("vma2".utf8), in: directory) != nil
    }

    /// The central directory's offset and size, read from the zip64 record the
    /// locator at `locator` points at.
    ///
    /// Every field here is remote-controlled, so each is checked to be
    /// representable as an `Int64` and to name a read that lands inside the file
    /// before it becomes a request. `nil` means the record is unusable.
    private func zip64DirectoryBounds(
        _ url: URL, tail: [UInt8], locator: Int, totalBytes: Int64
    ) async throws -> (offset: Int64, size: Int64)? {
        guard let recordOffset = Self.readLE(tail, locator + 8, UInt64.self),
            let recordStart = Int64(exactly: recordOffset),
            Self.fits(offset: recordStart, count: Self.zip64RecordWindow, within: totalBytes),
            let record = try await range(
                url, from: recordStart, count: Self.zip64RecordWindow),
            Array(record.prefix(4)) == [0x50, 0x4B, 0x06, 0x06],
            let size = Self.readLE(record, 40, UInt64.self),
            let offset = Self.readLE(record, 48, UInt64.self),
            let directorySize = Int64(exactly: size),
            let directoryOffset = Int64(exactly: offset)
        else { return nil }
        return (directoryOffset, directorySize)
    }

    /// Whether a `count`-byte read at `offset` lands wholly inside a file of `totalBytes`.
    private static func fits(offset: Int64, count: Int64, within totalBytes: Int64) -> Bool {
        guard offset >= 0, count > 0 else { return false }
        let (end, overflowed) = offset.addingReportingOverflow(count)
        return !overflowed && end <= totalBytes
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
