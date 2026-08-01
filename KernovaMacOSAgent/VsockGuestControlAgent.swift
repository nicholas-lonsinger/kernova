import Foundation
import KernovaKit
import os

/// The clock-independent surface of `VsockGuestControlAgent`, for holders that
/// must run below macOS 13 and so cannot store a concrete clock instantiation.
protocol VsockGuestControlling: AnyObject, Sendable {
    /// Begins the connect/serve/reconnect loop (idempotent).
    func start()
    /// Stops the loop and tears down any active channel.
    func stop()
    /// Thread-safe host-connection state for the menu-bar UI to pull on open.
    var connectionState: HostConnectionState { get }
    /// Thread-safe read of the host's bundled agent version; empty when unknown.
    var hostBundledAgentVersion: String { get }
    /// Thread-safe read of the negotiated gate for folder placeholder trees.
    var hostSupportsClipboardDirTree: Bool { get }
}

/// Builds a control agent on the platform-default clock — `ContinuousClock` on
/// macOS 13+, `CLOCK_MONOTONIC` below — erased for holders that run on 12.
func makeVsockGuestControlAgent(
    onPolicy: (@Sendable (Kernova_V1_PolicyUpdate) -> Void)? = nil,
    onStateChange: (@Sendable (HostConnectionState) -> Void)? = nil
) -> any VsockGuestControlling {
    if #available(macOS 13.0, *) {
        let clock = ContinuousEngineClock()
        return VsockGuestControlAgent(
            clock: clock,
            client: VsockGuestClient(port: KernovaVsockPort.control, label: "control", clock: clock),
            onPolicy: onPolicy,
            onStateChange: onStateChange
        )
    }
    let clock = MonotonicEngineClock()
    return VsockGuestControlAgent(
        clock: clock,
        client: VsockGuestClient(port: KernovaVsockPort.control, label: "control", clock: clock),
        onPolicy: onPolicy,
        onStateChange: onStateChange
    )
}

// File-scope stand-in for a `static let`, which a generic type cannot hold.
private let controlAgentLogger = Logger(
    subsystem: "app.kernova.macosagent", category: "VsockGuestControlAgent")

/// Guest-side control-channel agent that talks to the host's
/// `VsockControlService` on `KernovaVsockPort.control`.
///
/// The channel is always on, independent of any feature toggle, so the host can
/// detect agent presence and liveness even with clipboard sharing disabled. It
/// carries the version handshake, a recurring heartbeat, and a watchdog that
/// closes the channel once inbound traffic stops for `terminateAfter`, leaving
/// `VsockGuestClient` to rebuild it.
final class VsockGuestControlAgent<Clock: EngineClock>: VsockGuestControlling, @unchecked Sendable {
    private static var logger: Logger { controlAgentLogger }

    private let clock: Clock
    private let client: any VsockReconnecting
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
    private var lastInboundFrame: Clock.Instant?
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

    /// Whether the host advertised the folder placeholder-tree capability.
    ///
    /// Guarded by `lock` and reset per connection.
    private var hostSupportsClipboardDirTreeStorage = false

    /// Thread-safe read of the negotiated gate for folder placeholder trees.
    var hostSupportsClipboardDirTree: Bool { lock.withLock { hostSupportsClipboardDirTreeStorage } }

    /// Designated init; production goes through `makeVsockGuestControlAgent`,
    /// tests inject a socketpair-backed client and small cadences.
    init(
        clock: Clock,
        client: any VsockReconnecting,
        heartbeatInterval: TimeInterval = 5,
        unresponsiveAfter: TimeInterval = 15,
        terminateAfter: TimeInterval = 30,
        onPolicy: (@Sendable (Kernova_V1_PolicyUpdate) -> Void)? = nil,
        onStateChange: (@Sendable (HostConnectionState) -> Void)? = nil
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
        }
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
            let hostStreams = hello.capabilities.contains(KernovaCapability.clipboardStreamV1)
            let hostDirTree = hello.capabilities.contains(KernovaCapability.clipboardDirTreeV1)
            lock.withLock {
                hostSupportsClipboardStreaming = hostStreams
                hostSupportsClipboardDirTreeStorage = hostDirTree
                hostBundledAgentVersionStorage = hello.bundledAgentVersion
            }
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
                    "Host enabled clipboard but didn't advertise \(KernovaCapability.clipboardStreamV1, privacy: .public) — keeping clipboard disabled"
                )
            }
            Self.logger.notice(
                "PolicyUpdate received (logForwarding=\(effective.logForwardingEnabled, privacy: .public), clipboard=\(effective.clipboardSharingEnabled, privacy: .public))"
            )
            onPolicy?(effective)
        case .clipboardOffer, .clipboardRequest, .clipboardTreeFetch, .clipboardRelease,
            .clipboardStreamBegin, .clipboardChunk, .clipboardStreamEnd, .clipboardStreamAck,
            .clipboardStreamAbort, .logRecord, .none:
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
        let snapshot: (last: Clock.Instant?, alreadyLogged: Bool) = lock.withLock {
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
