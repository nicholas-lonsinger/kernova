import Foundation
import KernovaProtocol
import os

/// Snapshot of the toggle state delivered to the guest agent via
/// `PolicyUpdate` on the control channel. Decouples `VsockControlService`
/// from `VMConfiguration` — the host supplies a closure that reads the
/// fields each time policy is sent.
struct AgentPolicySnapshot: Equatable, Sendable {
    var logForwardingEnabled: Bool
    var clipboardSharingEnabled: Bool
}

/// Drives the always-on control channel between the host and the macOS guest
/// agent.
///
/// The control channel is independent of any feature toggle — its listener is
/// installed unconditionally for every macOS guest with a `VZVirtioSocketDevice`,
/// regardless of whether clipboard sharing is enabled. It carries:
/// - the bidirectional `Hello` handshake (each side advertises protocol
///   version, capabilities, and identifying agent info), and
/// - a bidirectional `Heartbeat` stream — each side sends one on a recurring
///   timer and treats extended silence from the peer as the peer being hung.
///
/// `agentStatus` is the single source of truth for "is the guest agent
/// installed, current, outdated, or unresponsive" on macOS guests. The UI reads
/// it via `VMInstance.agentStatus`.
///
/// One instance manages one channel for the lifetime of one accepted connection.
/// `stop()` is idempotent and is called both on explicit teardown and when the
/// liveness watchdog gives up after the terminate threshold. After teardown,
/// `VMInstance.startVsockServices()`'s accept callback will spawn a fresh
/// instance the next time the guest reconnects.
@MainActor
@Observable
final class VsockControlService {

    // MARK: - Observable state

    /// `true` once the guest agent has sent its `Hello`. Reset on `stop()`.
    private(set) var isConnected: Bool = false

    /// The guest-reported `Hello.agent_info.agent_version`. `nil` until the
    /// guest sends its `Hello`. Reset on `stop()`.
    private(set) var agentVersion: String?

    /// `true` when the inbound liveness watchdog has fired but the channel has
    /// not yet been torn down. Surfaces as `.unresponsive` in `agentStatus`.
    private(set) var isUnresponsive: Bool = false

    /// Whether the guest agent is missing, current, outdated, or unresponsive
    /// relative to the bundled binary. Drives sidebar / clipboard-window
    /// install/update affordances and the unresponsive indicator.
    var agentStatus: AgentStatus {
        guard let installed = agentVersion else { return .waiting }
        if isUnresponsive { return .unresponsive(version: installed) }
        // If the host's sidecar is missing (build regression), don't fight the
        // user with an "outdated" prompt — accept what the guest reports.
        guard let bundled = bundledAgentVersion else {
            return .current(version: installed)
        }
        // `.numeric` compares dotted decimals correctly: "0.9.0" < "0.10.0".
        // Only flag .outdated when installed is strictly older than bundled —
        // newer-than-bundled (development builds, downgraded host) shows as
        // .current.
        if installed.compare(bundled, options: .numeric) == .orderedAscending {
            return .outdated(installed: installed, bundled: bundled)
        }
        return .current(version: installed)
    }

    // MARK: - Private state

    private let channel: VsockChannel
    private let label: String
    private let bundledAgentVersion: String?
    private let heartbeatInterval: Duration
    private let unresponsiveAfter: Duration
    private let terminateAfter: Duration
    private let livenessTickInterval: Duration

    /// Reads the latest policy from the host configuration. Invoked once per
    /// guest `Hello` so the guest receives the current snapshot at every
    /// (re)connect. `nil` in tests that don't exercise policy delivery.
    private let policyProvider: (@MainActor () -> AgentPolicySnapshot)?

    private var consumeTask: Task<Void, Never>?
    private var outboundHeartbeatTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?

    /// Wall-clock instant of the most recent inbound frame (any kind — Hello
    /// and Heartbeat both count as liveness signals). `nil` until the first
    /// inbound frame arrives.
    private var lastInboundFrame: ContinuousClock.Instant?

    /// Outbound heartbeat sequence number. Echoed only for diagnostics — the
    /// peer does not respond to a specific nonce.
    private var nextHeartbeatNonce: UInt64 = 1

    private static let logger = Logger(subsystem: "com.kernova.app", category: "VsockControlService")

    // MARK: - Init

    init(
        channel: VsockChannel,
        label: String,
        bundledAgentVersion: String? = KernovaGuestAgentInfo.bundledVersion,
        heartbeatInterval: Duration = .seconds(5),
        unresponsiveAfter: Duration = .seconds(15),
        terminateAfter: Duration = .seconds(30),
        policyProvider: (@MainActor () -> AgentPolicySnapshot)? = nil
    ) {
        // The two-stage watchdog requires `unresponsiveAfter < terminateAfter`
        // so the `.unresponsive` UI transition is observable before the channel
        // is torn down. With the relation reversed, `terminateAfter` would fire
        // first and `.unresponsive` would never be reached.
        precondition(
            unresponsiveAfter < terminateAfter,
            "VsockControlService: unresponsiveAfter (\(unresponsiveAfter)) must be < terminateAfter (\(terminateAfter))"
        )
        self.channel = channel
        self.label = label
        self.bundledAgentVersion = bundledAgentVersion
        self.heartbeatInterval = heartbeatInterval
        self.unresponsiveAfter = unresponsiveAfter
        self.terminateAfter = terminateAfter
        // Check liveness several times per `unresponsiveAfter` so the
        // transition fires promptly. Capped at the heartbeat interval so tests
        // with very small thresholds don't over-spin.
        self.livenessTickInterval = min(heartbeatInterval, unresponsiveAfter / 3)
        self.policyProvider = policyProvider
    }

    // MARK: - Lifecycle

    func start() {
        guard consumeTask == nil else { return }

        sendHello()

        let channel = self.channel
        let label = self.label
        consumeTask = Task { [weak self] in
            await Self.consume(channel: channel, label: label) { @MainActor frame in
                self?.handle(frame: frame)
            }
        }

        let heartbeatInterval = self.heartbeatInterval
        outboundHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: heartbeatInterval)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                self?.sendHeartbeat()
            }
        }

        let livenessTickInterval = self.livenessTickInterval
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: livenessTickInterval)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                self?.checkLiveness()
            }
        }

        Self.logger.info("Vsock control service started for '\(self.label, privacy: .public)'")
    }

    func stop() {
        consumeTask?.cancel()
        consumeTask = nil
        outboundHeartbeatTask?.cancel()
        outboundHeartbeatTask = nil
        livenessTask?.cancel()
        livenessTask = nil
        channel.close()
        isConnected = false
        agentVersion = nil
        isUnresponsive = false
        lastInboundFrame = nil
        Self.logger.info("Vsock control service stopped for '\(self.label, privacy: .public)'")
    }

    // MARK: - Outbound

    private func sendHello() {
        var hello = Frame()
        hello.protocolVersion = 1
        hello.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities = ["control.v1", "control.heartbeat.v1"]
            $0.agentInfo = Kernova_V1_AgentInfo.with {
                $0.os = "macOS"
                $0.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
                $0.agentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "host"
            }
        }
        do {
            try channel.send(hello)
        } catch {
            Self.logger.error(
                "Failed to send control hello for '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Sends a `PolicyUpdate` frame carrying the current toggle snapshot to
    /// the guest. Called once on Hello receipt and again any time the user
    /// flips a hot-toggleable setting while the VM is running.
    func sendPolicyUpdate(_ policy: AgentPolicySnapshot) {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.policyUpdate = Kernova_V1_PolicyUpdate.with {
            $0.logForwardingEnabled = policy.logForwardingEnabled
            $0.clipboardSharingEnabled = policy.clipboardSharingEnabled
        }
        do {
            try channel.send(frame)
            Self.logger.notice(
                "Sent policy update for '\(self.label, privacy: .public)' (logForwarding=\(policy.logForwardingEnabled, privacy: .public), clipboard=\(policy.clipboardSharingEnabled, privacy: .public))"
            )
        } catch {
            Self.logger.error(
                "Failed to send policy update for '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func sendHeartbeat() {
        let nonce = nextHeartbeatNonce
        nextHeartbeatNonce += 1

        var frame = Frame()
        frame.protocolVersion = 1
        frame.heartbeat = Kernova_V1_Heartbeat.with {
            $0.nonce = nonce
        }
        do {
            try channel.send(frame)
        } catch {
            // A failed send usually means the channel just tore down. The
            // consume task will see EOF momentarily and the listener will
            // accept a fresh connection. Log at .debug — no further fallback.
            Self.logger.debug(
                "Failed to send heartbeat for '\(self.label, privacy: .public)' (nonce=\(nonce, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Liveness

    private func checkLiveness() {
        guard let last = lastInboundFrame else {
            // No inbound frame ever — agent hasn't connected. `.waiting` is
            // already what `agentStatus` reports; nothing to update.
            return
        }
        let elapsed = ContinuousClock.now - last
        if elapsed > terminateAfter {
            Self.logger.warning(
                "Control channel for '\(self.label, privacy: .public)' silent for \(elapsed.formatted(.units(allowed: [.seconds])), privacy: .public) — closing"
            )
            // Tearing the channel down lets the consume task return and the
            // listener accept a fresh connection. stop() is idempotent so the
            // subsequent VMInstance teardown is safe.
            channel.close()
        } else if elapsed > unresponsiveAfter {
            if !isUnresponsive {
                Self.logger.warning(
                    "Control channel for '\(self.label, privacy: .public)' silent for \(elapsed.formatted(.units(allowed: [.seconds])), privacy: .public) — marking unresponsive"
                )
                isUnresponsive = true
            }
        } else {
            if isUnresponsive {
                Self.logger.notice(
                    "Control channel for '\(self.label, privacy: .public)' resumed responding"
                )
                isUnresponsive = false
            }
        }
    }

    // MARK: - Inbound

    private static func consume(
        channel: VsockChannel,
        label: String,
        dispatch: @MainActor @escaping (Frame) -> Void
    ) async {
        do {
            for try await frame in channel.incoming {
                dispatch(frame)
            }
            logger.info("Vsock control channel closed for '\(label, privacy: .public)'")
        } catch {
            logger.warning(
                "Vsock control channel ended with error for '\(label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func handle(frame: Frame) {
        guard frame.protocolVersion == 1 else {
            Self.logger.warning(
                "Dropping frame with unsupported protocol version \(frame.protocolVersion, privacy: .public) for '\(self.label, privacy: .public)'"
            )
            return
        }

        // Any inbound traffic counts as liveness. Refresh before dispatch so a
        // recovering channel clears `.unresponsive` on the next liveness tick.
        lastInboundFrame = ContinuousClock.now

        switch frame.payload {
        case .hello(let hello):
            isConnected = true
            isUnresponsive = false
            let reportedVersion = hello.agentInfo.agentVersion
            agentVersion = reportedVersion.isEmpty ? nil : reportedVersion
            Self.logger.notice(
                "Guest agent connected for '\(self.label, privacy: .public)' (service=\(hello.serviceVersion, privacy: .public), agent=\(reportedVersion, privacy: .public), caps=\(hello.capabilities.joined(separator: ","), privacy: .public))"
            )
            // Push the current policy snapshot to the freshly connected guest
            // so it stops/starts log + clipboard work immediately rather than
            // assuming defaults.
            if let provider = policyProvider {
                sendPolicyUpdate(provider())
            }
        case .heartbeat:
            // The frame itself is the signal — nothing more to do beyond the
            // `lastInboundFrame` refresh above. Recovery from `.unresponsive`
            // happens on the next `checkLiveness()` tick.
            Self.logger.debug(
                "Heartbeat from '\(self.label, privacy: .public)'"
            )
        case .error(let error):
            Self.logger.warning(
                "Guest control error for '\(self.label, privacy: .public)': \(error.code, privacy: .public) — \(error.message, privacy: .public)"
            )
        case .policyUpdate, .clipboardOffer, .clipboardRequest, .clipboardData, .clipboardRelease, .logRecord, .none:
            // PolicyUpdate is a host→guest message and never arrives on the
            // host side; other payloads belong on other channels. Log and
            // ignore.
            Self.logger.warning(
                "Unexpected payload on control channel for '\(self.label, privacy: .public)' — wrong port"
            )
        }
    }
}
