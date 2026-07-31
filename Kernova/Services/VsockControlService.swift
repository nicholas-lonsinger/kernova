import Foundation
import KernovaKit
import os

/// Snapshot of the toggle state delivered to the guest agent via `PolicyUpdate` on the control channel.
struct AgentPolicySnapshot: Equatable, Sendable {
    var logForwardingEnabled: Bool
    var clipboardSharingEnabled: Bool
}

/// Guest-reported identity from one `Hello.agent_info`, with an empty
/// `os_version` normalized to `nil`.
///
/// No default on `osVersion`: a `nil` overwrites the persisted value, so every
/// construction site must say it means "clear", not omit it and mean "keep".
struct ObservedAgentInfo: Equatable, Sendable {
    var agentVersion: String
    var osVersion: String?
}

/// Drives the always-on control channel between the host and the macOS guest
/// agent.
///
/// The listener is installed for every macOS guest with a
/// `VZVirtioSocketDevice`, independent of any feature toggle, and carries the
/// bidirectional `Hello` handshake plus a `Heartbeat` stream where extended
/// peer silence means the peer is hung. One instance manages one channel for
/// one accepted connection; `stop()` is idempotent.
@MainActor
@Observable
final class VsockControlService {
    // MARK: - Observable state

    /// `true` once the guest agent has sent its `Hello`; reset on `stop()`.
    private(set) var isConnected: Bool = false

    /// The guest-reported `Hello.agent_info.agent_version`, `nil` until that
    /// `Hello` arrives and again after `stop()`.
    private(set) var agentVersion: String?

    /// `true` when the inbound liveness watchdog has fired but the channel has not yet been torn down.
    private(set) var isUnresponsive: Bool = false

    /// Whether the guest agent is missing, current, outdated, or unresponsive relative to the bundled binary.
    var agentStatus: AgentStatus {
        guard let installed = agentVersion else { return .waiting }
        if isUnresponsive { return .unresponsive(version: installed) }
        guard let bundled = bundledAgentVersion else {
            return .current(version: installed)
        }
        return AgentStatus.isObservedVersionCurrent(installed, bundled: bundled)
            ? .current(version: installed)
            : .outdated(installed: installed, bundled: bundled)
    }

    // MARK: - Private state

    private let channel: VsockChannel
    private let label: String
    private let bundledAgentVersion: String?
    private let heartbeatInterval: Duration
    private let unresponsiveAfter: Duration
    private let terminateAfter: Duration
    private let livenessTickInterval: Duration

    /// Reads the latest policy from the host configuration.
    ///
    /// Invoked once per guest `Hello` so the guest receives the current snapshot at every (re)connect.
    private let policyProvider: (@MainActor () -> AgentPolicySnapshot)?

    /// Notified each time the guest reports a non-empty `agentVersion` in its `Hello`.
    ///
    /// Fire-and-forget — this service does not care whether the host persists the value.
    private let onAgentInfoObserved: (@MainActor (ObservedAgentInfo) -> Void)?

    private var consumeTask: Task<Void, Never>?
    private var outboundHeartbeatTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?

    /// Instant of the most recent inbound frame of any kind — `Hello` and
    /// `Heartbeat` both count as liveness signals.
    private var lastInboundFrame: ContinuousClock.Instant?

    /// Outbound heartbeat sequence number, for diagnostics only — the peer does
    /// not respond to a specific nonce.
    private var nextHeartbeatNonce: UInt64 = 1

    /// Whether the connected guest agent advertised the streaming-clipboard
    /// capability in its `Hello`.
    ///
    /// Set on Hello, reset on stop. Gates the clipboard bit of every
    /// `PolicyUpdate` we send, so an agent that can't stream never has clipboard
    /// sharing turned on.
    private var guestSupportsClipboardStreamingStorage = false

    /// Whether the guest agent advertised the folder placeholder-tree capability
    /// (`clipboard.dirtree.v1`) in its `Hello`.
    ///
    /// Set on Hello, reset on stop. Decides whether a directory rep crosses as a
    /// placeholder tree or the eager-archive fallback.
    private var guestSupportsClipboardDirTreeStorage = false

    /// Whether the guest advertised `clipboard.dirtree.v1` — the mutually
    /// negotiated gate for folder placeholder trees.
    var guestSupportsClipboardDirTree: Bool { guestSupportsClipboardDirTreeStorage }

    /// Whether the guest advertised `clipboard.stream.v1` — the capability the
    /// clipboard-channel admission check requires.
    var guestSupportsClipboardStreaming: Bool { guestSupportsClipboardStreamingStorage }

    private static let logger = Logger(subsystem: "app.kernova", category: "VsockControlService")

    // MARK: - Init

    init(
        channel: VsockChannel,
        label: String,
        bundledAgentVersion: String? = KernovaMacOSAgentInfo.bundledVersion,
        heartbeatInterval: Duration = .seconds(5),
        unresponsiveAfter: Duration = .seconds(15),
        terminateAfter: Duration = .seconds(30),
        policyProvider: (@MainActor () -> AgentPolicySnapshot)? = nil,
        onAgentInfoObserved: (@MainActor (ObservedAgentInfo) -> Void)? = nil
    ) {
        // The two-stage watchdog requires `unresponsiveAfter < terminateAfter`:
        // reversed, `terminateAfter` fires first and `.unresponsive` is never
        // reached.
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
        // transition fires promptly, capped at the heartbeat interval.
        self.livenessTickInterval = min(heartbeatInterval, unresponsiveAfter / 3)
        self.policyProvider = policyProvider
        self.onAgentInfoObserved = onAgentInfoObserved
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
        guestSupportsClipboardStreamingStorage = false
        guestSupportsClipboardDirTreeStorage = false
        Self.logger.info("Vsock control service stopped for '\(self.label, privacy: .public)'")
    }

    // MARK: - Outbound

    private func sendHello() {
        var hello = Frame()
        hello.protocolVersion = 1
        hello.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities = KernovaCapability.controlChannelDefaults
            // Tell the guest which agent version this host bundles so it can show
            // its own update state. Empty when the sidecar is missing — the guest
            // treats empty as "unknown" and shows no update prompt.
            $0.bundledAgentVersion = bundledAgentVersion ?? ""
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

    /// Sends a `PolicyUpdate` frame carrying the current toggle snapshot to the guest.
    ///
    /// Called on Hello receipt and whenever the user flips a hot-toggleable setting while the VM
    /// is running.
    func sendPolicyUpdate(_ policy: AgentPolicySnapshot) {
        // An agent that can't stream never gets clipboard turned on.
        let clipboardEnabled = policy.clipboardSharingEnabled && guestSupportsClipboardStreaming
        if policy.clipboardSharingEnabled && !guestSupportsClipboardStreaming {
            Self.logger.notice(
                "Clipboard sharing requested but guest agent for '\(self.label, privacy: .public)' lacks the \(KernovaCapability.clipboardStreamV1, privacy: .public) capability — keeping clipboard disabled (agent needs updating)"
            )
        }
        var frame = Frame()
        frame.protocolVersion = 1
        frame.policyUpdate = Kernova_V1_PolicyUpdate.with {
            $0.logForwardingEnabled = policy.logForwardingEnabled
            $0.clipboardSharingEnabled = clipboardEnabled
        }
        do {
            try channel.send(frame)
            Self.logger.notice(
                "Sent policy update for '\(self.label, privacy: .public)' (logForwarding=\(policy.logForwardingEnabled, privacy: .public), clipboard=\(clipboardEnabled, privacy: .public))"
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
            // A failed send usually means the channel just tore down: the
            // consume task sees EOF momentarily and the listener accepts a
            // fresh connection.
            Self.logger.debug(
                "Failed to send heartbeat for '\(self.label, privacy: .public)' (nonce=\(nonce, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Liveness

    private func checkLiveness() {
        guard let last = lastInboundFrame else {
            // No inbound frame ever — the agent hasn't connected, and
            // `agentStatus` already reports `.waiting`.
            return
        }
        let elapsed = ContinuousClock.now - last
        if elapsed > terminateAfter {
            Self.logger.warning(
                "Control channel for '\(self.label, privacy: .public)' silent for \(elapsed.formatted(.units(allowed: [.seconds])), privacy: .public) — closing"
            )
            // Tearing the channel down lets the consume task return and the
            // listener accept a fresh connection.
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
            let reportedOSVersion = hello.agentInfo.osVersion
            guestSupportsClipboardStreamingStorage = hello.capabilities.contains(
                KernovaCapability.clipboardStreamV1)
            guestSupportsClipboardDirTreeStorage = hello.capabilities.contains(
                KernovaCapability.clipboardDirTreeV1)
            // `logDescription` bounds the peer-supplied capability strings so a
            // malicious peer can't write arbitrary content into the host log.
            Self.logger.notice(
                "Guest agent connected for '\(self.label, privacy: .public)' (service=\(hello.serviceVersion, privacy: .public), agent=\(reportedVersion, privacy: .public), caps=\(KernovaCapability.logDescription(of: hello.capabilities), privacy: .public))"
            )
            // An empty agent version means the agent didn't populate the field
            // — skip those so the host doesn't persist a meaningless value.
            if !reportedVersion.isEmpty {
                onAgentInfoObserved?(
                    ObservedAgentInfo(
                        agentVersion: reportedVersion,
                        osVersion: reportedOSVersion.isEmpty ? nil : reportedOSVersion))
            }
            // Push the current policy to the freshly connected guest so it
            // doesn't run on assumed defaults.
            if let provider = policyProvider {
                sendPolicyUpdate(provider())
            }
        case .heartbeat:
            // The frame itself is the signal; recovery from `.unresponsive`
            // happens on the next `checkLiveness()` tick.
            Self.logger.debug(
                "Heartbeat from '\(self.label, privacy: .public)'"
            )
        case .error(let error):
            Self.logger.warning(
                "Guest control error for '\(self.label, privacy: .public)': \(error.code, privacy: .public) — \(error.message, privacy: .public)"
            )
        case .policyUpdate, .clipboardOffer, .clipboardRequest, .clipboardTreeFetch,
            .clipboardRelease, .clipboardStreamBegin, .clipboardChunk, .clipboardStreamEnd,
            .clipboardStreamAck, .clipboardStreamAbort, .logRecord, .none:
            // PolicyUpdate is host→guest and never arrives here; other payloads
            // belong on other channels. RATIONALE: the clipboard and log
            // channels close on a wrong-port payload, but this one stays up —
            // it is the admission anchor they gate on, so closing it would flap
            // the agent-status UI and every dependent channel on one stray
            // frame.
            Self.logger.warning(
                "Unexpected payload on control channel for '\(self.label, privacy: .public)' — wrong port"
            )
        }
    }
}
