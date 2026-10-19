import Foundation
import KernovaKit
import KernovaLogging
import KernovaSynchronization

/// Guest-side control-channel agent that talks to the host's
/// `VsockControlService` on `KernovaVsockPort.control`.
///
/// The channel is always on, independent of any feature toggle, so the host can
/// detect agent presence and liveness even with clipboard sharing disabled. It
/// carries the version handshake, a recurring heartbeat, and a watchdog that
/// closes the channel once inbound traffic stops for `terminateAfter`, leaving
/// `VsockGuestClient` to rebuild it.
final class VsockGuestControlAgent: Sendable {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova.macosagent", category: "VsockGuestControlAgent")

    private let clock: any EngineClock
    private let client: VsockGuestClient
    private let cadence: ControlChannelCadence

    /// Invoked on every inbound `PolicyUpdate`, with the raw protobuf snapshot.
    private let onPolicy: (@Sendable (Kernova_V1_PolicyUpdate) -> Void)?

    /// Invoked whenever `connectionState` changes.
    ///
    /// Called off the main thread; the receiver must hop to the main actor.
    private let onStateChange: (@Sendable (HostConnectionState) -> Void)?

    private let state: Locked<State>

    private struct State: Sendable {
        var nextHeartbeatNonce: UInt64 = 1

        /// Connection state surfaced to the menu-bar UI.
        ///
        /// Set only through `transition(to:)`, so the change callback fires
        /// exactly on real transitions.
        private(set) var connectionState: HostConnectionState = .connecting

        /// The guest-agent version the host bundles, learned from its `Hello`;
        /// empty means unknown, which the UI shows as no update.
        var hostBundledAgentVersion = ""

        /// Whether the host advertised the streaming-clipboard capability.
        ///
        /// Reset per connection; gates the clipboard bit of every inbound
        /// `PolicyUpdate`, symmetric with the host's own gate.
        var hostSupportsClipboardStreaming = false

        /// The two-stage silence watchdog, shared with the host service, and
        /// reset per connection by ``serve(channel:)``.
        var liveness: ControlLivenessMonitor

        init(cadence: ControlChannelCadence) {
            liveness = ControlLivenessMonitor(cadence: cadence)
        }

        /// Moves to `newState`, and returns whether that changed anything.
        mutating func transition(to newState: HostConnectionState) -> Bool {
            guard connectionState != newState else { return false }
            connectionState = newState
            return true
        }

        mutating func takeHeartbeatNonce() -> UInt64 {
            defer { nextHeartbeatNonce += 1 }
            return nextHeartbeatNonce
        }
    }

    /// Invoked whenever the host's advertised capabilities change — on each
    /// `Hello`, and on each connection teardown that clears them — with
    /// whether the host now takes files dropped on the VM display.
    ///
    /// A host without that capability runs no drop listener, so the guest's
    /// drop client stays paused rather than redialling a port nothing is bound
    /// to. Separate from `onStateChange`, which is change-gated on a state
    /// already set to `.connected` before any `Hello` arrives and so never
    /// fires for the capabilities themselves. Called off the main thread.
    private let onHostCapabilitiesChanged: (@Sendable (_ hostSupportsDropFiles: Bool) -> Void)?

    /// Creates the control agent; tests inject a socketpair-backed client and
    /// small cadences.
    init(
        clock: any EngineClock = makePlatformEngineClock(),
        client: VsockGuestClient = VsockGuestClient(
            port: KernovaVsockPort.control, label: "control"),
        cadence: ControlChannelCadence = .production,
        onPolicy: (@Sendable (Kernova_V1_PolicyUpdate) -> Void)? = nil,
        onStateChange: (@Sendable (HostConnectionState) -> Void)? = nil,
        onHostCapabilitiesChanged: (@Sendable (_ hostSupportsDropFiles: Bool) -> Void)? = nil
    ) {
        self.clock = clock
        self.client = client
        self.cadence = cadence
        self.state = Locked(State(cadence: cadence))
        self.onPolicy = onPolicy
        self.onStateChange = onStateChange
        self.onHostCapabilitiesChanged = onHostCapabilitiesChanged
    }

    // MARK: - UI state accessors

    /// Host-connection state for the menu-bar UI to pull on open.
    var connectionState: HostConnectionState {
        state.withLock { $0.connectionState }
    }

    /// The host's bundled agent version; empty when unknown.
    var hostBundledAgentVersion: String {
        state.withLock { $0.hostBundledAgentVersion }
    }

    // MARK: - Lifecycle

    /// Begins the connect/serve/reconnect loop (idempotent).
    func start() {
        client.start { [weak self] channel in
            await self?.serve(channel: channel)
        }
        Self.logger.log(.notice, "Vsock control agent started")
    }

    /// Stops the loop and tears down any active channel.
    func stop() {
        client.stop()
        Self.logger.log(.notice, "Vsock control agent stopped")
    }

    // MARK: - Per-connection serve

    private func serve(channel: VsockChannel) async {
        // Neither a stale liveness clock nor a stale capability may leak across
        // connections.
        let connected = state.withLock { state in
            state.liveness.reset()
            state.hostSupportsClipboardStreaming = false
            return state.transition(to: .connected)
        }
        // The clearing is a capability change like any other: a client enabled by
        // the previous host's Hello has to stand down until this one says Hello.
        onHostCapabilitiesChanged?(false)
        if connected { onStateChange?(.connected) }

        sendHello(on: channel)

        let heartbeatTask = repeatingClockTask(
            clock: clock, every: cadence.heartbeatInterval
        ) { [weak self] in
            self?.sendHeartbeat(on: channel)
        }
        let livenessTask = repeatingClockTask(
            clock: clock, every: cadence.livenessTickInterval
        ) { [weak self] in
            self?.checkLiveness(channel: channel)
        }
        defer {
            heartbeatTask.cancel()
            livenessTask.cancel()
            if state.withLock({ $0.transition(to: .connecting) }) { onStateChange?(.connecting) }
        }

        do {
            for try await frame in channel.incoming {
                handle(frame: frame)
            }
            Self.logger.log(.notice, "Vsock control channel closed by host")
        } catch {
            Self.logger.log(
                .warning,
                "Vsock control channel ended with error: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Inbound

    private func handle(frame: Frame) {
        let inbound = ControlChannelInbound.classify(frame)
        // Any inbound traffic counts as liveness.
        if inbound.isLivenessSignal {
            let now = clock.now
            let reconnected = state.withLock { state in
                state.liveness.record(at: now)
                return state.transition(to: .connected)
            }
            if reconnected { onStateChange?(.connected) }
        }

        switch inbound {
        case .unsupportedVersion(let version):
            Self.logger.log(
                .warning,
                "Dropping frame with unsupported protocol version \(version, privacy: .public)"
            )
        case .hello(let hello):
            let hostStreams = hello.capabilities.contains(KernovaCapability.clipboardTransferV3)
            let hostTakesDrops = hello.capabilities.contains(KernovaCapability.dropFilesV3)
            state.withLock { state in
                state.hostSupportsClipboardStreaming = hostStreams
                state.hostBundledAgentVersion = hello.bundledAgentVersion
            }
            onHostCapabilitiesChanged?(hostTakesDrops)
            // `logDescription` bounds the peer-supplied capability strings; these
            // records can be forwarded into the host's log store.
            Self.logger.log(
                .notice,
                "Host control service ready (service=\(hello.serviceVersion, privacy: .public), caps=\(KernovaCapability.logDescription(of: hello.capabilities), privacy: .public))"
            )
        case .heartbeat:
            // The frame itself is the signal; the liveness clock is refreshed above.
            break
        case .error(let error):
            Self.logger.log(
                .warning,
                "Host control error: \(error.code, privacy: .public) — \(error.message, privacy: .public)"
            )
        case .policyUpdate(let policy):
            // Symmetric capability gate: ignore a clipboard-enable from a host
            // that didn't advertise streaming support.
            let hostStreams = state.withLock { $0.hostSupportsClipboardStreaming }
            var effective = policy
            effective.clipboardSharingEnabled = policy.clipboardSharingEnabled && hostStreams
            if policy.clipboardSharingEnabled && !hostStreams {
                Self.logger.log(
                    .notice,
                    "Host enabled clipboard but didn't advertise \(KernovaCapability.clipboardTransferV3, privacy: .public) — keeping clipboard disabled"
                )
            }
            Self.logger.log(
                .notice,
                "PolicyUpdate received (logForwarding=\(effective.logForwardingEnabled, privacy: .public), clipboard=\(effective.clipboardSharingEnabled, privacy: .public))"
            )
            onPolicy?(effective)
        case .wrongPort:
            Self.logger.log(.warning, "Unexpected payload on control channel — wrong port")
        }
    }

    // MARK: - Outbound

    private func sendHello(on channel: VsockChannel) {
        let hello = Frame.controlHello(
            agentVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
                ?? "unknown")
        do {
            try channel.send(hello)
        } catch {
            Self.logger.log(
                .warning,
                "Failed to send control Hello: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func sendHeartbeat(on channel: VsockChannel) {
        let nonce = state.withLock { $0.takeHeartbeatNonce() }
        do {
            try channel.send(Frame.controlHeartbeat(nonce: nonce))
        } catch {
            // A failed send usually means the channel just tore down; the serve
            // loop sees EOF and `VsockGuestClient` reconnects.
            Self.logger.log(
                .debug,
                "Failed to send heartbeat (nonce=\(nonce, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Liveness

    private func checkLiveness(channel: VsockChannel) {
        let now = clock.now
        let (verdict, becameUnresponsive) = state.withLock { state in
            let verdict = state.liveness.evaluate(at: now)
            guard case .becameUnresponsive = verdict else { return (verdict, false) }
            return (verdict, state.transition(to: .unresponsive))
        }
        switch verdict {
        case .unchanged, .recovered:
            // The host hasn't sent anything yet, or nothing crossed a stage —
            // keep waiting. An evaluation never recovers a peer; the inbound
            // frame that does is what `handle(frame:)` reconnects on.
            break
        case .becameUnresponsive(let silentFor):
            Self.logger.log(
                .warning,
                "Host control channel silent for \(Int(silentFor.rounded()), privacy: .public) s — host appears unresponsive"
            )
            if becameUnresponsive { onStateChange?(.unresponsive) }
        case .expired(let silentFor):
            Self.logger.log(
                .warning,
                "Host control channel silent for \(Int(silentFor.rounded()), privacy: .public) s — closing"
            )
            channel.close()
        }
    }
}
