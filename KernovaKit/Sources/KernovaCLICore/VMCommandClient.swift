import Darwin
import Foundation
import KernovaKit

/// The tool's end of the app's command socket.
///
/// Blocking on purpose: the tool is one request and one answer, so a run loop
/// would buy nothing and a plain `read`/`write` is what makes the exit code the
/// only thing a caller has to interpret.
public final class VMCommandClient {
    private let fd: Int32
    private var decoder = StreamFrameDecoder()
    private var isClosed = false

    /// Connects to the socket at `path`.
    ///
    /// - Throws: ``CLIFailure`` with ``CLIExitCode/unavailable`` when nothing
    ///   is listening there — the app is not running, or this build resolves no
    ///   app-group container to hold the socket.
    public init(socketPath: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw CLIFailure(.unavailable, "Could not open a socket: \(Self.reason(errno)).")
        }
        var address: sockaddr_un
        do {
            address = try UnixSocketAddress.make(path: socketPath)
        } catch {
            Darwin.close(descriptor)
            throw CLIFailure(.unavailable, "The socket path is too long: \(socketPath)")
        }
        let connected = UnixSocketAddress.withSockaddr(&address) { socketAddress, length in
            connect(descriptor, socketAddress, length)
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw CLIFailure(.unavailable, "Kernova is not answering: \(Self.reason(code)).")
        }
        fd = descriptor
    }

    deinit { close() }

    /// Sends one verb and reads the single answer.
    public func send(_ verb: VMCommandRequest.Verb) throws -> VMCommandResponse {
        try write(try JSONEncoder().encode(VMCommandRequest(verb: verb)))
        guard let response = try nextResponse() else {
            throw CLIFailure(.unavailable, "Kernova closed the connection without answering.")
        }
        return response
    }

    /// Sends the subscribe verb and vends the snapshot frame, then one element
    /// per library event, until the app hangs up.
    ///
    /// The iterator throws nothing: a read failure ends it, which is what a
    /// `for` loop over a stream that stopped should see.
    public func subscribe() throws -> AnyIterator<VMCommandResponse> {
        try write(try JSONEncoder().encode(VMCommandRequest(verb: .events)))
        return AnyIterator { [weak self] in
            guard let self else { return nil }
            return try? self.nextResponse()
        }
    }

    /// Closes the connection; idempotent.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fd)
    }

    // MARK: - Frames

    private func write(_ payload: Data) throws {
        let framed = try StreamFrame.encode(payload)
        var offset = 0
        try framed.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if errno == EINTR { continue }
                throw CLIFailure(
                    .unavailable, "Could not reach Kernova: \(Self.reason(errno)).")
            }
        }
    }

    /// The next framed answer, or `nil` once the app hangs up.
    private func nextResponse() throws -> VMCommandResponse? {
        while true {
            // A frame this build will not buffer means the peer is not the one
            // it thinks; the stream is unusable from that point either way.
            let pending: Data?
            do {
                pending = try decoder.nextFrame()
            } catch {
                throw CLIFailure(.unavailable, "Kernova sent a frame this tool cannot read.")
            }
            if let frame = pending {
                guard
                    let response = try? JSONDecoder().decode(
                        VMCommandResponse.self, from: Data(frame))
                else {
                    throw CLIFailure(.unavailable, "Kernova sent an answer this tool cannot read.")
                }
                return response
            }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                decoder.feed(Data(buffer[0..<count]))
                continue
            }
            if count == 0 { return nil }  // EOF
            if errno == EINTR { continue }
            throw CLIFailure(.unavailable, "Lost the connection to Kernova: \(Self.reason(errno)).")
        }
    }

    /// `errno` in the words `strerror` gives it.
    private static func reason(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

extension VMCommandResponse {
    /// The payload this answer carries, or the failure it carries as the exit
    /// the tool takes.
    ///
    /// The single site any refusal — a verb's or the envelope's — becomes an
    /// exit code and a sentence.
    public func payload() throws -> Result {
        switch result {
        case .failure(let error):
            throw CLIFailure(CLIExitCode(error), error.message)
        case .refused(let refusal):
            throw CLIFailure(CLIExitCode(refusal), Self.message(for: refusal))
        default:
            return result
        }
    }

    private static func message(for refusal: VMCommandTransportRefusal) -> String {
        switch refusal {
        case .authorizationRefused(let reason):
            reason
        case .unsupportedProtocolVersion(let peer, let expected):
            "This Kernova speaks command version \(peer); the tool speaks \(expected). "
                + "The app and the tool it installed are different versions — reinstall the tool "
                + "from Settings \u{2192} Advanced."
        case .undecodableRequest(let detail):
            "Kernova could not read the request: \(detail)"
        }
    }
}
