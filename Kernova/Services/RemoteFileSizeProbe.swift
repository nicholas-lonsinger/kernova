import Foundation

/// Why a remote file's length could not be read.
///
/// Not shown to anyone as it stands: a caller states the refusal in the terms
/// of whatever it was about to download.
enum RemoteFileSizeError: Error, Equatable {
    case insecureURL
    case unreachable(statusCode: Int)
    case unknownSize
    case rangeRequestsUnsupported
    case transportFailed(description: String)
}

/// Reads how large a remote file is, without downloading it.
///
/// A value type over a session the caller owns, so the one service that also
/// reads a file's bytes and the one that only needs its length share a single
/// answer to "how big is this".
struct RemoteFileSizeProbe: Sendable {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    /// The file's length in bytes.
    ///
    /// `HEAD` answers it wherever a server implements it. A server that refuses
    /// `HEAD` — pre-signed S3 and CloudFront links answer 403, others 405 —
    /// still serves ranged `GET`s, so a non-2xx `HEAD` is not fatal: the
    /// one-byte ranged `GET`'s `Content-Range` settles the size, and its status
    /// settles whether the URL is live at all. A scheme other than `https` is
    /// refused before any request is issued, and the returned size is always
    /// greater than zero.
    func size(of url: URL) async throws -> UInt64 {
        guard url.scheme?.lowercased() == "https" else {
            throw RemoteFileSizeError.insecureURL
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
            throw RemoteFileSizeError.unknownSize
        }
        guard response.statusCode == 206 else {
            // 2xx that isn't 206 means the Range header was ignored and the body
            // is the whole file, which is neither a size nor something to read.
            guard (200..<300).contains(response.statusCode) else {
                throw RemoteFileSizeError.unreachable(statusCode: response.statusCode)
            }
            throw RemoteFileSizeError.rangeRequestsUnsupported
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
            throw RemoteFileSizeError.unknownSize
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
            throw RemoteFileSizeError.transportFailed(description: error.localizedDescription)
        }
    }
}
