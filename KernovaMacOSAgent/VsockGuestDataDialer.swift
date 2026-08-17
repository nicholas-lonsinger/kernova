import Foundation
import KernovaKit

/// Opens one clipboard transfer's data connection to the host.
///
/// macOS guests only ever initiate vsock connections, so every transfer — in
/// either direction — is dialled from here. The connect itself reuses
/// `VsockGuestClient`'s per-OS paths, so the OS quirks that bound a connect are
/// solved once; what this adds is a gate label of its own, so a data connect
/// parked against a host that stopped accepting cannot spend the reconnect
/// loop's own budget of parked attempts.
enum VsockGuestDataDialer {
    /// Gate label for data connections, keeping their parked-connect budget
    /// apart from any channel's.
    static let gateLabel = "data"

    /// Connects to `port` on the host and returns the descriptor, with the data
    /// connection's socket options applied.
    ///
    /// - Throws: ``VsockProviderError`` when the connect does not complete
    ///   inside `VsockGuestClient.connectTimeoutSeconds`, or at all.
    static func connect(
        port: UInt32, label: String = gateLabel, socketProvider: VsockSocketProvider? = nil
    ) throws -> Int32 {
        let provider =
            socketProvider ?? { port, label in
                VsockGuestClient.openVsockToHost(
                    port: port, label: label, clock: makePlatformEngineClock())
            }
        switch provider(port, label) {
        case .success(let fd):
            ClipboardDataConnection.applySocketOptions(fd: fd, role: .guest)
            return fd
        case .failure(let error):
            throw error
        }
    }
}
