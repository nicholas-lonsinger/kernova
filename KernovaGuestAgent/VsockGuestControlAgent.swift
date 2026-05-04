import Foundation
import KernovaProtocol
import os

/// Guest-side control-channel agent that talks to the host's `VsockControlService`
/// on `KernovaVsockPort.control` (49154).
///
/// The control channel is the always-on home for the agent's version handshake
/// and a bidirectional heartbeat. It is independent of any feature toggle on
/// the host — even when clipboard sharing is disabled this connection still
/// runs, so the host can detect agent presence and liveness.
///
/// Per-connection responsibilities:
/// - Send `Hello` immediately on connect, advertising agent OS / version /
///   capabilities.
/// - Send `Heartbeat` frames on a recurring timer (default 5 s).
/// - Refresh a "last inbound frame" clock from any inbound traffic. If that
///   clock falls more than `terminateAfter` (default 30 s) behind, assume the
///   host is hung and close the channel — `VsockGuestClient.runReconnectLoop`
///   will rebuild it.
///
/// Connection lifecycle (connect, retry on failure, EOF) is owned by
/// `VsockGuestClient`. This class layers the control protocol on top.
///
/// RATIONALE: Logs use raw `os.Logger` rather than `KernovaLogger`. The log
/// channel and this control channel share the same vsock device; routing
/// connection-lifecycle logs through `KernovaLogger` would risk a feedback
/// loop where a heartbeat send failure schedules another forwarded log frame
/// through the same broken transport.
final class VsockGuestControlAgent: @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.kernova.agent", category: "VsockGuestControlAgent")

    private let client: VsockGuestClient
    private let heartbeatInterval: Duration
    private let unresponsiveAfter: Duration
    private let terminateAfter: Duration
    private let livenessTickInterval: Duration

    private let lock = NSLock()
    private var lastInboundFrame: ContinuousClock.Instant?
    private var unresponsiveLogged: Bool = false
    private var nextHeartbeatNonce: UInt64 = 1

    /// Production init — connects to the control port with default cadences.
    convenience init() {
        self.init(
            client: VsockGuestClient(port: KernovaVsockPort.control, label: "control")
        )
    }

    /// Designated init; tests inject a socketpair-backed client and small cadences.
    init(
        client: VsockGuestClient,
        heartbeatInterval: Duration = .seconds(5),
        unresponsiveAfter: Duration = .seconds(15),
        terminateAfter: Duration = .seconds(30)
    ) {
        // The two-stage watchdog requires `unresponsiveAfter < terminateAfter`
        // so the "host appears unresponsive" warning is observable before the
        // channel is torn down. With the relation reversed, `terminateAfter`
        // would fire first and the unresponsive log path would never run.
        precondition(
            unresponsiveAfter < terminateAfter,
            "VsockGuestControlAgent: unresponsiveAfter (\(unresponsiveAfter)) must be < terminateAfter (\(terminateAfter))"
        )
        self.client = client
        self.heartbeatInterval = heartbeatInterval
        self.unresponsiveAfter = unresponsiveAfter
        self.terminateAfter = terminateAfter
        // Check liveness several times per `unresponsiveAfter`. Capped at the
        // heartbeat interval so tests with very small thresholds don't
        // over-spin.
        self.livenessTickInterval = min(heartbeatInterval, unresponsiveAfter / 3)
    }

    // MARK: - Lifecycle

    /// Begins the connect/serve/reconnect loop. Idempotent.
    func start() {
        client.start { [weak self] channel in
            await self?.serve(channel: channel)
        }
        Self.logger.notice("Vsock control agent started")
    }

    /// Stops the loop and tears down any active channel.
    func stop() {
        client.stop()
        Self.logger.notice("Vsock control agent stopped")
    }

    // MARK: - Per-connection serve

    private func serve(channel: VsockChannel) async {
        // Reset per-connection state so `checkLiveness` doesn't fire on a
        // stale clock from the previous connection.
        lock.withLock {
            lastInboundFrame = nil
            unresponsiveLogged = false
        }

        sendHello(on: channel)

        let heartbeatInterval = self.heartbeatInterval
        let livenessTickInterval = self.livenessTickInterval
        let heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: heartbeatInterval)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                self?.sendHeartbeat(on: channel)
            }
        }
        let livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: livenessTickInterval)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                self?.checkLiveness(channel: channel)
            }
        }
        defer {
            heartbeatTask.cancel()
            livenessTask.cancel()
        }

        do {
            for try await frame in channel.incoming {
                handle(frame: frame)
            }
            Self.logger.notice("Vsock control channel closed by host")
        } catch {
            Self.logger.warning(
                "Vsock control channel ended with error: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Inbound

    private func handle(frame: Frame) {
        guard frame.protocolVersion == 1 else {
            Self.logger.warning(
                "Dropping frame with unsupported protocol version \(frame.protocolVersion, privacy: .public)"
            )
            return
        }

        // Any inbound traffic counts as liveness.
        lock.withLock {
            lastInboundFrame = ContinuousClock.now
            unresponsiveLogged = false
        }

        switch frame.payload {
        case .hello(let hello):
            Self.logger.notice(
                "Host control service ready (service=\(hello.serviceVersion, privacy: .public), caps=\(hello.capabilities.joined(separator: ","), privacy: .public))"
            )
        case .heartbeat:
            // The frame itself is the signal. Liveness clock already refreshed.
            break
        case .error(let error):
            Self.logger.warning(
                "Host control error: \(error.code, privacy: .public) — \(error.message, privacy: .public)"
            )
        case .clipboardOffer, .clipboardRequest, .clipboardData, .clipboardRelease, .logRecord, .none:
            Self.logger.warning("Unexpected payload on control channel — wrong port")
        }
    }

    // MARK: - Outbound

    private func sendHello(on channel: VsockChannel) {
        var hello = Frame()
        hello.protocolVersion = 1
        hello.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities = ["control.v1", "control.heartbeat.v1"]
            $0.agentInfo = Kernova_V1_AgentInfo.with {
                $0.os = "macOS"
                $0.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
                $0.agentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
            }
        }
        do {
            try channel.send(hello)
        } catch {
            Self.logger.warning(
                "Failed to send control Hello: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func sendHeartbeat(on channel: VsockChannel) {
        let nonce = lock.withLock {
            defer { nextHeartbeatNonce += 1 }
            return nextHeartbeatNonce
        }
        var frame = Frame()
        frame.protocolVersion = 1
        frame.heartbeat = Kernova_V1_Heartbeat.with {
            $0.nonce = nonce
        }
        do {
            try channel.send(frame)
        } catch {
            // A failed send usually means the channel just tore down; the
            // serve loop will see EOF momentarily and VsockGuestClient will
            // reconnect. Log at .debug — no further fallback.
            Self.logger.debug(
                "Failed to send heartbeat (nonce=\(nonce, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Liveness

    private func checkLiveness(channel: VsockChannel) {
        let snapshot: (last: ContinuousClock.Instant?, alreadyLogged: Bool) = lock.withLock {
            (lastInboundFrame, unresponsiveLogged)
        }
        guard let last = snapshot.last else {
            // Host hasn't sent anything yet — keep waiting.
            return
        }
        let elapsed = ContinuousClock.now - last
        if elapsed > terminateAfter {
            Self.logger.warning(
                "Host control channel silent for \(elapsed.formatted(.units(allowed: [.seconds])), privacy: .public) — closing"
            )
            // Tearing down lets serve()'s read loop see EOF and return; the
            // reconnect loop in VsockGuestClient will rebuild.
            channel.close()
        } else if elapsed > unresponsiveAfter {
            if !snapshot.alreadyLogged {
                Self.logger.warning(
                    "Host control channel silent for \(elapsed.formatted(.units(allowed: [.seconds])), privacy: .public) — host appears unresponsive"
                )
                lock.withLock { unresponsiveLogged = true }
            }
        }
    }
}
