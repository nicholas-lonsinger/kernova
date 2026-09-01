import Foundation
import KernovaKit
import os

/// Snapshot of the toggle state delivered to the guest agent via `PolicyUpdate` on the control channel.
struct AgentPolicySnapshot: Equatable, Sendable {
    var logForwardingEnabled: Bool
    var clipboardSharingEnabled: Bool

    /// Whether the guest's drop agent should dial the drop port. The host binds
    /// that port only while this is set, so a guest told otherwise would be
    /// refused on every retry.
    var dropFilesEnabled: Bool

    /// The user-selected ceiling on a paste's file-representation total, which
    /// the guest enforces against its own inbound pastes.
    var clipboardMaxPasteBytes: Int
}

/// Guest-reported identity from one `Hello.agent_info`, with each version field
/// bounded and an empty one normalized to `nil`.
///
/// No default on `osVersion`: a `nil` overwrites the persisted value, so every
/// construction site must say it means "clear", not omit it and mean "keep".
struct ObservedAgentInfo: Equatable, Sendable {
    var agentVersion: String
    var osVersion: String?

    /// Ceiling, in UTF-8 bytes, on either version field.
    ///
    /// `Hello.agent_info` is peer-supplied and bounded on the wire only by
    /// `VsockFrame.maxPayloadSize`, while the host persists both fields to
    /// `config.json`, renders them in its UI, interpolates them into its log,
    /// and scans `os_version` with an `NSRegularExpression` on the main actor.
    /// A dotted-decimal version — with room for a build suffix — needs nothing
    /// like this much.
    static let maxFieldBytes = 64

    /// `reported` stripped of control and format characters and clipped to
    /// ``maxFieldBytes``, or `nil` when nothing printable survives.
    ///
    /// The single intake normalization for both fields, so every downstream
    /// consumer inherits it instead of defending itself. Both halves earn their
    /// place: cutting by UTF-8 length rather than by `Character` is what makes
    /// the bound hold, since one grapheme cluster can carry unboundedly many
    /// combining scalars; and length alone leaves the host logging, persisting
    /// and rendering 64 arbitrary bytes, where a newline forges a log line and
    /// a bidi override rewrites the label the string appears in. A version
    /// string has legitimate use for neither.
    static func boundedField(_ reported: String) -> String? {
        var bounded = String.UnicodeScalarView()
        var byteCount = 0
        // Bounded scan: nothing past `maxFieldBytes` scalars can widen the
        // result, and this runs on the main actor against a payload the peer
        // sizes. `controlCharacters` covers Unicode Cc and Cf both — the
        // newlines and the bidi overrides.
        for scalar in reported.unicodeScalars.prefix(maxFieldBytes)
        where !CharacterSet.controlCharacters.contains(scalar) {
            byteCount += UTF8.width(scalar)
            // Whole scalars only — a cut landing mid-scalar would have to be
            // repaired with U+FFFD, which is wider than the bytes it replaces.
            guard byteCount <= maxFieldBytes else { break }
            bounded.append(scalar)
        }
        return bounded.isEmpty ? nil : String(bounded)
    }
}

/// Drives the always-on control channel between the host and the macOS guest
/// agent.
///
/// The listener is installed for every macOS guest with a
/// `VZVirtioSocketDevice`, independent of any feature toggle, and carries the
/// bidirectional `Hello` handshake plus a `Heartbeat` stream where extended
/// peer silence — while the guest is executing — means the peer is hung. One
/// instance manages one channel for
/// one accepted connection and stops itself once that channel dies, whether the
/// peer closed it or the watchdog did; `stop()` is idempotent and terminal, so
/// a reconnect is served by a fresh instance.
@MainActor
@Observable
final class VsockControlService: VsockFeatureService {
    // MARK: - Observable state

    /// `true` once the guest agent has sent its `Hello`; reset when the
    /// connection settles.
    private(set) var isConnected: Bool = false

    /// The guest-reported `Hello.agent_info.agent_version`, `nil` until that
    /// `Hello` arrives and again once the connection settles.
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

    /// Time source for both timer loops and every liveness measurement — one
    /// seam, so a test stepping the heartbeat cadence also holds the watchdog's
    /// clock.
    private let clock: any EngineClock
    private let cadence: ControlChannelCadence

    /// The two-stage silence watchdog, shared with the guest agent.
    private let liveness: ControlLivenessMonitor

    /// Reads the latest policy from the host configuration.
    ///
    /// Invoked once per guest `Hello` so the guest receives the current snapshot at every (re)connect.
    private let policyProvider: (@MainActor () -> AgentPolicySnapshot)?

    /// Notified each time the guest reports a non-empty `agentVersion` in its `Hello`.
    ///
    /// Fire-and-forget — this service does not care whether the host persists the value.
    private let onAgentInfoObserved: (@MainActor (ObservedAgentInfo) -> Void)?

    /// Reports whether the guest is frozen (the VM is live-paused).
    ///
    /// Read at every liveness tick and before every outbound heartbeat, so it
    /// tracks pause/resume without the owner having to push transitions in.
    private let isGuestSuspended: (@MainActor () -> Bool)?

    /// Where the feature listeners' accept path reads this handshake's state.
    ///
    /// Published on `Hello` and reset when the service settles, whichever of
    /// the owner, the watchdog, or the channel's own end settles it.
    private let admissionGate: VsockAdmissionGate?

    private var consumeTask: Task<Void, Never>?
    private var outboundHeartbeatTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?

    /// Guards the teardown against re-entry: the liveness watchdog, the consume
    /// task and the owner can each reach `stop()`, and whichever arrives first
    /// is the one that settles.
    private var hasStopped = false

    #if DEBUG
    /// The tasks `start()` spun up, so a test can await their completion instead
    /// of polling for the watchdog to fall silent.
    ///
    /// Read it before the teardown that clears them.
    var lifecycleTasksForTesting: [Task<Void, Never>] {
        [consumeTask, outboundHeartbeatTask, livenessTask].compactMap { $0 }
    }
    #endif

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

    /// Whether the guest advertised `clipboard.transfer.v3` — the capability the
    /// clipboard-channel admission check requires.
    var guestSupportsClipboardStreaming: Bool { guestSupportsClipboardStreamingStorage }

    /// Whether the connected guest agent advertised `drop.files.v3` in its
    /// `Hello`.
    ///
    /// Set on Hello, reset on stop. An agent without it runs no drop client, so
    /// the display refuses the gesture rather than offering files nothing will
    /// pull.
    private var guestSupportsDropFilesStorage = false

    /// Whether the guest can receive files dropped onto the VM display.
    var guestSupportsDropFiles: Bool { guestSupportsDropFilesStorage }

    // MARK: - Settle contract

    /// Notified once when the channel dies on its own, never on an
    /// owner-requested `stop()`.
    @ObservationIgnored var onChannelLost: (@MainActor () -> Void)?

    private static let logger = Logger(subsystem: "app.kernova", category: "VsockControlService")

    // MARK: - Init

    init(
        channel: VsockChannel,
        label: String,
        bundledAgentVersion: String? = KernovaMacOSAgentInfo.bundledVersion,
        clock: any EngineClock = makePlatformEngineClock(),
        cadence: ControlChannelCadence = .production,
        policyProvider: (@MainActor () -> AgentPolicySnapshot)? = nil,
        onAgentInfoObserved: (@MainActor (ObservedAgentInfo) -> Void)? = nil,
        isGuestSuspended: (@MainActor () -> Bool)? = nil,
        admissionGate: VsockAdmissionGate? = nil
    ) {
        self.channel = channel
        self.label = label
        self.bundledAgentVersion = bundledAgentVersion
        self.clock = clock
        self.cadence = cadence
        self.liveness = ControlLivenessMonitor(cadence: cadence)
        self.policyProvider = policyProvider
        self.onAgentInfoObserved = onAgentInfoObserved
        self.isGuestSuspended = isGuestSuspended
        self.admissionGate = admissionGate
    }

    // MARK: - Lifecycle

    func start() {
        guard consumeTask == nil, !hasStopped else { return }

        sendHello()

        let channel = self.channel
        let label = self.label
        consumeTask = Task { [weak self] in
            await Self.consume(channel: channel, label: label) { @MainActor frame in
                self?.handle(frame: frame)
            }
            // The channel is gone once `consume` returns; settle so the
            // heartbeat and liveness tasks stop running against a dead socket.
            self?.stop(reason: .channelLost)
        }

        outboundHeartbeatTask = repeatingClockTask(
            clock: clock, every: cadence.heartbeatInterval
        ) { [weak self] in
            await self?.sendHeartbeat()
        }

        livenessTask = repeatingClockTask(
            clock: clock, every: cadence.livenessTickInterval
        ) { [weak self] in
            await self?.checkLiveness()
        }

        Self.logger.info("Vsock control service started for '\(self.label, privacy: .public)'")
    }

    /// Tears the service down at the owner's request and resets the handshake
    /// state.
    ///
    /// The owner is not called back — it already knows. Involuntary channel
    /// death routes through `stop(reason: .channelLost)` instead.
    func stop() {
        stop(reason: .ownerRequested)
    }

    /// Tears the service down and resets the handshake state, telling the owner
    /// when the channel died rather than being closed on purpose.
    ///
    /// Safe to call from inside the tasks it cancels: `Task.cancel()` only sets
    /// the cancellation flag, so a caller running inside the liveness or consume
    /// task runs this method to completion and then unwinds at its own next
    /// cancellation check. The `hasStopped` latch makes `onChannelLost` fire at
    /// most once, and never after an owner teardown has already settled.
    private func stop(reason: VsockSettleReason) {
        guard !hasStopped else { return }
        hasStopped = true
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
        liveness.reset()
        guestSupportsClipboardStreamingStorage = false
        guestSupportsDropFilesStorage = false
        admissionGate?.clear()
        Self.logger.info("Vsock control service stopped for '\(self.label, privacy: .public)'")
        // Last, so the owner observes fully-settled state — notably a nil
        // `agentVersion` — from inside the callback.
        if case .channelLost = reason {
            onChannelLost?()
        }
    }

    // MARK: - Outbound

    private func sendHello() {
        // Tell the guest which agent version this host bundles so it can show
        // its own update state. Empty when the sidecar is missing — the guest
        // treats empty as "unknown" and shows no update prompt.
        let hello = Frame.controlHello(
            agentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "host",
            bundledAgentVersion: bundledAgentVersion ?? "")
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
                "Clipboard sharing requested but guest agent for '\(self.label, privacy: .public)' lacks the \(KernovaCapability.clipboardTransferV3, privacy: .public) capability — keeping clipboard disabled (agent needs updating)"
            )
        }
        var frame = Frame()
        frame.protocolVersion = 1
        frame.policyUpdate = Kernova_V1_PolicyUpdate.with {
            $0.logForwardingEnabled = policy.logForwardingEnabled
            $0.clipboardSharingEnabled = clipboardEnabled
            $0.clipboardMaxPasteBytes = UInt64(policy.clipboardMaxPasteBytes)
            $0.dropFilesEnabled = policy.dropFilesEnabled
        }
        do {
            try channel.send(frame)
            Self.logger.notice(
                "Sent policy update for '\(self.label, privacy: .public)' (logForwarding=\(policy.logForwardingEnabled, privacy: .public), clipboard=\(clipboardEnabled, privacy: .public), maxPasteBytes=\(policy.clipboardMaxPasteBytes, privacy: .public), dropFiles=\(policy.dropFilesEnabled, privacy: .public))"
            )
        } catch {
            Self.logger.error(
                "Failed to send policy update for '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func sendHeartbeat() {
        // A frozen guest drains nothing, and `VsockChannel.writeFramed` parks in
        // a blocking `write(2)` once the peer's receive buffer fills — here, on
        // the main actor. Send nothing while the guest is suspended.
        guard !(isGuestSuspended?() ?? false) else { return }

        let nonce = nextHeartbeatNonce
        nextHeartbeatNonce += 1

        do {
            try channel.send(Frame.controlHeartbeat(nonce: nonce))
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
        // The timer bodies hop onto the main actor, so a tick cancelled by the
        // teardown can still land after it — nothing may re-arm settled state.
        guard !hasStopped else { return }
        // A live-paused guest is frozen, not silent: it cannot answer, so
        // host-side elapsed time says nothing about the agent's health. Hold
        // the deadline at now for as long as it stays frozen, so the guest is
        // judged only on time it spends executing. This is also what survives
        // host sleep: the VM is auto-paused for it, and an `EngineClock` counts
        // the time the system spends asleep.
        if isGuestSuspended?() ?? false {
            apply(liveness.record(at: clock.now))
            return
        }
        apply(liveness.evaluate(at: clock.now))
    }

    /// Reacts to one watchdog verdict, wherever it was reached from.
    ///
    /// Every write to `isUnresponsive` is here: the monitor emits each stage
    /// crossing once, so an `@Observable` notification tracks the transition
    /// rather than the tick.
    private func apply(_ verdict: ControlLivenessMonitor.Verdict) {
        switch verdict {
        case .noSignal, .unchanged:
            // No inbound frame ever, or nothing changed — with no frame,
            // `agentStatus` already reports `.waiting`.
            break
        case .becameUnresponsive(let silentFor):
            Self.logger.warning(
                "Control channel for '\(self.label, privacy: .public)' silent for \(Int(silentFor.rounded()), privacy: .public) s — marking unresponsive"
            )
            isUnresponsive = true
        case .recovered:
            Self.logger.notice(
                "Control channel for '\(self.label, privacy: .public)' resumed responding"
            )
            isUnresponsive = false
        case .expired(let silentFor):
            Self.logger.warning(
                "Control channel for '\(self.label, privacy: .public)' silent for \(Int(silentFor.rounded()), privacy: .public) s — closing"
            )
            stop(reason: .channelLost)
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
        // A frame still buffered in `incoming` when the teardown ran would
        // otherwise flip `isConnected` back on for a channel whose tasks are
        // already cancelled.
        guard !hasStopped else { return }
        let inbound = ControlChannelInbound.classify(frame)
        // Any inbound traffic counts as liveness. Refresh before dispatch, so a
        // channel that resumed talking is out of `.unresponsive` by the time
        // this frame's own handling reads the state.
        if inbound.isLivenessSignal { apply(liveness.record(at: clock.now)) }

        switch inbound {
        case .unsupportedVersion(let version):
            Self.logger.warning(
                "Dropping frame with unsupported protocol version \(version, privacy: .public) for '\(self.label, privacy: .public)'"
            )
        case .hello(let hello):
            isConnected = true
            // Both version fields are peer-supplied — `boundedField` is the one
            // intake every downstream consumer inherits.
            let reportedVersion = ObservedAgentInfo.boundedField(hello.agentInfo.agentVersion)
            agentVersion = reportedVersion
            let reportedOSVersion = ObservedAgentInfo.boundedField(hello.agentInfo.osVersion)
            guestSupportsClipboardStreamingStorage = hello.capabilities.contains(
                KernovaCapability.clipboardTransferV3)
            guestSupportsDropFilesStorage = hello.capabilities.contains(
                KernovaCapability.dropFilesV3)
            admissionGate?.publish(
                VsockAdmissionGate.State(
                    handshakeComplete: true, capabilities: Set(hello.capabilities)))
            // Every peer-supplied piece of this line is filtered first — the
            // version by `boundedField`, the capability tags by
            // `logDescription` — so none of them can write arbitrary content
            // into the host log.
            Self.logger.notice(
                "Guest agent connected for '\(self.label, privacy: .public)' (service=\(hello.serviceVersion, privacy: .public), agent=\(reportedVersion ?? "?", privacy: .public), caps=\(KernovaCapability.logDescription(of: hello.capabilities), privacy: .public))"
            )
            // An empty agent version means the agent didn't populate the field
            // — skip those so the host doesn't persist a meaningless value.
            if let reportedVersion {
                onAgentInfoObserved?(
                    ObservedAgentInfo(
                        agentVersion: reportedVersion, osVersion: reportedOSVersion))
            }
            // Push the current policy to the freshly connected guest so it
            // doesn't run on assumed defaults.
            if let provider = policyProvider {
                sendPolicyUpdate(provider())
            }
        case .heartbeat:
            // The frame itself is the signal, already recorded above.
            Self.logger.debug(
                "Heartbeat from '\(self.label, privacy: .public)'"
            )
        case .error(let error):
            Self.logger.warning(
                "Guest control error for '\(self.label, privacy: .public)': \(error.code, privacy: .public) — \(error.message, privacy: .public)"
            )
        case .policyUpdate, .wrongPort:
            // PolicyUpdate is host→guest and never arrives here; other payloads
            // belong on other channels. RATIONALE: verified 2026-09-01 against
            // this file's teardown path — the clipboard and log channels close
            // on a wrong-port payload, but this one stays up, because it is the
            // admission anchor they gate on (`admissionGate?.clear()` in
            // `stop`), so closing it would flap the agent-status UI and every
            // dependent channel on one stray frame.
            Self.logger.warning(
                "Unexpected payload on control channel for '\(self.label, privacy: .public)' — wrong port"
            )
        }
    }
}
