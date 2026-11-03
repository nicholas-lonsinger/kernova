#if os(macOS)
import Darwin
import Dispatch
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaPlatformPOSIX
import KernovaWire

/// Dials the host over vsock from a macOS guest: ``DarwinVsockConnect``'s bounded connect on the protocol's
/// port, run on the dialer's own queue, handed on as a `POSIXByteStream` once it completes.
public struct DarwinVsockDialer: TransportDialer {
    /// The label the connect's parked-attempt budget is kept under.
    static let label = "agent"

    private let port: UInt32
    private let queue = DispatchQueue(label: "app.kernova.vsock-dial")

    /// A dialer for the host's `port`.
    public init(port: UInt32 = WireConstants.vsockPort) {
        self.port = port
    }

    public func dial(_ completion: @escaping @Sendable (Result<any ByteStream, DialFailure>) -> Void) {
        queue.async { [port] in
            switch DarwinVsockConnect.connect(port: port, label: Self.label) {
            case .failure(.permanent): completion(.failure(.permanent))
            case .failure(.transient): completion(.failure(.transient))
            case .success(let descriptor):
                do throws(ByteStreamError) {
                    completion(.success(try POSIXByteStream(adopting: descriptor)))
                } catch {
                    close(descriptor)
                    completion(.failure(.transient))
                }
            }
        }
    }
}
#endif
