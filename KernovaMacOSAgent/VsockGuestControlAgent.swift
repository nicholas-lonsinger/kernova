import Foundation
import KernovaKit
import os

/// Guest-side control-channel agent that talks to the host's
/// `VsockControlService` on `KernovaVsockPort.control`.
///
/// The channel is always on, independent of any feature toggle, so the host can
/// detect agent presence and liveness even with clipboard sharing disabled. It
/// carries the version handshake, a recurring heartbeat, and a watchdog that
/// closes the channel once inbound traffic stops for `terminateAfter`, leaving
/// `VsockGuestClient` to rebuild it.
final class VsockGuestControlAgent: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "app.kernova.macosagent", category: "VsockGuestControlAgent")

    private let clock: any EngineClock
    private let client: VsockGuestClient
    private let heartbeatInterval: TimeInterval
    private let unresponsiveAfter: TimeInterval
    private let terminateAfter: TimeInterval
    private let livenessTickInterval: TimeInterval

    /// Invoked on every inbound `PolicyUpdate`, with the raw protobuf snapshot.
    private let onPolicy: (@Sendable (Kernova_V1_PolicyUpdate) -> Void)?

    /// Invoked whenever `connectionState` changes.
    ///
    /// Called off the main thread; the receiver must hop to the main actor.
    private let onStateChange: (@Sendable (HostConnectionState) -> Void)?

    private let lock = NSLock()
    private var lastInboundFrame: EngineInstant?
    private var unresponsiveLogged: Bool = false
    private var nextHeartbeatNonce: UInt64 = 1

    /// Connection state surfaced to the menu-bar UI.
    ///
    /// Guarded by `lock`; mutate only through `updateConnectionState(_:)` so the
    /// change callback fires exactly on real transitions.
    private var connectionStateStorage: HostConnectionState = .connecting

    /// The guest-agent version the host bundles, learned from its `Hello`.
    ///
    /// Guarded by `lock`; empty means unknown, which the UI shows as no update.
    private var hostBundledAgentVersionStorage: String = ""

    /// Whether the host advertised the streaming-clipboard capability.
    ///
    /// Guarded by `lock` and reset per connection; gates the clipboard bit of
    /// every inbound `PolicyUpdate`, symmetric with the host's own gate.
    private var hostSupportsClipboardStreaming = false

    /// Whether the host advertised the display-drop capability.
    ///
    /// Guarded by `lock` and reset per connection; a host without it runs no drop
    /// listener, so the guest's drop client stays paused rather than redialling a
    /// port nothing is bound to.
    private var hostSupportsDropFilesStorage = false

    /// Invoked whenever the host's advertised capabilities change — on each
    /// `Hello`, and on each connection teardown that clears them.
    ///
    /// Separate from `onStateChange`, which is change-gated on a state already
    /// set to `.connected` before any `Hello` arrives and so never fires for the
    /// capabilities themselves. Called off the main thread.
    private let onHostCapabilitiesChanged: (@Sendable () -> Void)?

    /// Creates the control agent; tests inject a socketpair-backed client and
    /// small cadences.
    init(
        clock: any EngineClock = makePlatformEngineClock(),
        client: VsockGuestClient = VsockGuestClient(
            port: KernovaVsockPort.control, label: "control"),
        heartbeatInterval: TimeInterval = 5,
        unresponsiveAfter: TimeInterval = 15,
        terminateAfter: TimeInterval = 30,
        onPolicy: (@Sendable (Kernova_V1_PolicyUpdate) -> Void)? = nil,
        onStateChange: (@Sendable (HostConnectionState) -> Void)? = nil,
        onHostCapabilitiesChanged: (@Sendable () -> Void)? = nil
    ) {
        precondition(
            unresponsiveAfter < terminateAfter,
            "VsockGuestControlAgent: unresponsiveAfter (\(unresponsiveAfter)) must be < terminateAfter (\(terminateAfter))"
        )
        self.clock = clock
        self.client = client
        self.heartbeatInterval = heartbeatInterval
        self.unresponsiveAfter = unresponsiveAfter
        self.terminateAfter = terminateAfter
        // Several checks per `unresponsiveAfter`, capped at the heartbeat
        // interval so small test thresholds don't over-spin.
        self.livenessTickInterval = min(heartbeatInterval, unresponsiveAfter / 3)
        self.onPolicy = onPolicy
        self.onStateChange = onStateChange
        self.onHostCapabilitiesChanged = onHostCapabilitiesChanged
    }

    // MARK: - UI state accessors

    /// Thread-safe host-connection state for the menu-bar UI to pull on open.
    var connectionState: HostConnectionState {
        lock.withLock { connectionStateStorage }
    }

    /// Thread-safe read of the host's bundled agent version; empty when unknown.
    var hostBundledAgentVersion: String {
        lock.withLock { hostBundledAgentVersionStorage }
    }

    /// Thread-safe read of whether the host takes files dropped on the VM
    /// display.
    var hostSupportsDropFiles: Bool {
        lock.withLock { hostSupportsDropFilesStorage }
    }

    /// Transitions `connectionState`, firing `onStateChange` only on a real
    /// change.
    ///
    /// Must not be called while already holding `lock` (NSLock is not reentrant).
    private func updateConnectionState(_ newState: HostConnectionState) {
        let changed: Bool = lock.withLock {
            guard connectionStateStorage != newState else { return false }
            connectionStateStorage = newState
            return true
        }
        if changed { onStateChange?(newState) }
    }

    // MARK: - Lifecycle

    /// Begins the connect/serve/reconnect loop (idempotent).
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
        // Neither a stale liveness clock nor a stale capability may leak across
        // connections.
        lock.withLock {
            lastInboundFrame = nil
            unresponsiveLogged = false
            hostSupportsClipboardStreaming = false
            hostSupportsDropFilesStorage = false
        }
        // The clearing is a capability change like any other: a client enabled by
        // the previous host's Hello has to stand down until this one says Hello.
        onHostCapabilitiesChanged?()
        updateConnectionState(.connected)

        sendHello(on: channel)

        let heartbeatInterval = self.heartbeatInterval
        let livenessTickInterval = self.livenessTickInterval
        let clock = self.clock
        let heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: heartbeatInterval)
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
                    try await clock.sleep(for: livenessTickInterval)
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
            updateConnectionState(.connecting)
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
            lastInboundFrame = clock.now
            unresponsiveLogged = false
        }
        updateConnectionState(.connected)

        switch frame.payload {
        case .hello(let hello):
            let hostStreams = hello.capabilities.contains(KernovaCapability.clipboardTransferV3)
            let hostTakesDrops = hello.capabilities.contains(KernovaCapability.dropFilesV3)
            lock.withLock {
                hostSupportsClipboardStreaming = hostStreams
                hostSupportsDropFilesStorage = hostTakesDrops
                hostBundledAgentVersionStorage = hello.bundledAgentVersion
            }
            onHostCapabilitiesChanged?()
            // `logDescription` bounds the peer-supplied capability strings; these
            // records can be forwarded into the host's log store.
            Self.logger.notice(
                "Host control service ready (service=\(hello.serviceVersion, privacy: .public), caps=\(KernovaCapability.logDescription(of: hello.capabilities), privacy: .public))"
            )
        case .heartbeat:
            // The frame itself is the signal; the liveness clock is refreshed above.
            break
        case .error(let error):
            Self.logger.warning(
                "Host control error: \(error.code, privacy: .public) — \(error.message, privacy: .public)"
            )
        case .policyUpdate(let policy):
            // Symmetric capability gate: ignore a clipboard-enable from a host
            // that didn't advertise streaming support.
            let hostStreams = lock.withLock { hostSupportsClipboardStreaming }
            var effective = policy
            effective.clipboardSharingEnabled = policy.clipboardSharingEnabled && hostStreams
            if policy.clipboardSharingEnabled && !hostStreams {
                Self.logger.notice(
                    "Host enabled clipboard but didn't advertise \(KernovaCapability.clipboardTransferV3, privacy: .public) — keeping clipboard disabled"
                )
            }
            Self.logger.notice(
                "PolicyUpdate received (logForwarding=\(effective.logForwardingEnabled, privacy: .public), clipboard=\(effective.clipboardSharingEnabled, privacy: .public))"
            )
            onPolicy?(effective)
        case .clipboardOffer, .clipboardRequest, .clipboardRelease,
            .clipboardTransferRequest, .clipboardTransferReply, .logRecord,
            .dropOffer, .dropComplete, .dropRelease, .none:
            Self.logger.warning("Unexpected payload on control channel — wrong port")
        }
    }

    // MARK: - Outbound

    private func sendHello(on channel: VsockChannel) {
        var hello = Frame()
        hello.protocolVersion = 1
        hello.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities = KernovaCapability.controlChannelDefaults
            $0.agentInfo = Kernova_V1_AgentInfo.with {
                $0.os = "macOS"
                $0.osVersion = KernovaOSVersion.current
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
            // A failed send usually means the channel just tore down; the serve
            // loop sees EOF and `VsockGuestClient` reconnects.
            Self.logger.debug(
                "Failed to send heartbeat (nonce=\(nonce, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Liveness

    private func checkLiveness(channel: VsockChannel) {
        let snapshot: (last: EngineInstant?, alreadyLogged: Bool) = lock.withLock {
            (lastInboundFrame, unresponsiveLogged)
        }
        guard let last = snapshot.last else {
            // Host hasn't sent anything yet — keep waiting.
            return
        }
        let elapsed = clock.seconds(since: last)
        if elapsed > terminateAfter {
            Self.logger.warning(
                "Host control channel silent for \(Int(elapsed.rounded()), privacy: .public) s — closing"
            )
            channel.close()
        } else if elapsed > unresponsiveAfter {
            if !snapshot.alreadyLogged {
                Self.logger.warning(
                    "Host control channel silent for \(Int(elapsed.rounded()), privacy: .public) s — host appears unresponsive"
                )
                lock.withLock { unresponsiveLogged = true }
            }
            updateConnectionState(.unresponsive)
        }
    }
}
