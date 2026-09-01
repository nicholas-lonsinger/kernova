import Foundation
import KernovaKit
import os

/// One vsock feature channel, described once: the ports it binds, what gates
/// them, which slot on the coordinator holds its service, and what a channel
/// dying under that service means for the slot.
///
/// Every closure takes the coordinator (or the VM) as an argument instead of
/// capturing one, so a descriptor is a session-independent constant that holds
/// nothing and can never close a retain cycle over what it drives.
struct VsockFeatureDescriptor {
    /// A framed channel's per-transfer data port, which rises and falls with
    /// the channel port: a data port that outlived it would admit a transfer no
    /// service is left to serve.
    struct DataPort {
        let port: UInt32

        /// Where the listener lands each accepted connection — the sink the
        /// coordinator points at whichever service currently owns the channel.
        let sink: KeyPath<VsockFeatureCoordinator, VsockDataConnectionSink>
    }

    /// This channel's name in test failure messages.
    let name: String

    /// The framed channel port.
    let port: UInt32

    /// The data port paired with this channel, or `nil` for one that carries
    /// everything in frames.
    let data: DataPort?

    /// The guest capability an accepted connection needs beyond the completed
    /// control handshake, or `nil` for a listener that admits unconditionally.
    let requirement: FeatureChannelRequirement?

    /// Whether a configuration installs this channel at all.
    let isEnabled: @MainActor (VMConfiguration) -> Bool

    /// Whether a change to ``isEnabled`` may be applied to a running VM.
    ///
    /// Separate from ``isEnabled`` on purpose: clipboard sharing is
    /// install-time gated for every guest but live-toggled only for macOS ones,
    /// and a single predicate would live-toggle vsock listeners on a Linux
    /// guest whose sharing rides the SPICE console port.
    let appliesLive: @MainActor (VMConfiguration) -> Bool

    /// Reads this channel's service slot.
    let current: @MainActor (VsockFeatureCoordinator) -> (any VsockFeatureService)?

    /// Builds the service for one accepted channel, fills the slot, and points
    /// the data sink at it.
    let install:
        @MainActor (VsockFeatureCoordinator, VMInstance, VsockChannel) ->
            any VsockFeatureService

    /// Empties the slot and the data sink.
    let clear: @MainActor (VsockFeatureCoordinator) -> Void

    /// Whether a channel that died under its service empties the slot too, or
    /// the settled service stays referenced until the next accept replaces it.
    let releasesSlotOnChannelLoss: Bool

    /// What a lost channel does beyond the slot.
    let onChannelLost: (@MainActor (VMInstance) -> Void)?

    /// What runs once an accepted service has started.
    let afterAccept: (@MainActor (VMInstance) -> Void)?

    /// Every port this channel binds, the framed port first.
    var ports: [UInt32] { data.map { [port, $0.port] } ?? [port] }
}

/// The two shapes a channel takes, each building the slot accessors its
/// service type needs without a cast at the use site.
@MainActor
extension VsockFeatureDescriptor {
    /// A framed channel whose service serves that channel alone.
    static func channel<Service: VsockFeatureService>(
        name: String,
        port: UInt32,
        requirement: FeatureChannelRequirement?,
        isEnabled: @escaping @MainActor (VMConfiguration) -> Bool,
        appliesLive: @escaping @MainActor (VMConfiguration) -> Bool = { _ in true },
        slot: ReferenceWritableKeyPath<VsockFeatureCoordinator, Service?>,
        releasesSlotOnChannelLoss: Bool = false,
        onChannelLost: (@MainActor (VMInstance) -> Void)? = nil,
        afterAccept: (@MainActor (VMInstance) -> Void)? = nil,
        make: @escaping @MainActor (VMInstance, VsockChannel) -> Service
    ) -> VsockFeatureDescriptor {
        VsockFeatureDescriptor(
            name: name,
            port: port,
            data: nil,
            requirement: requirement,
            isEnabled: isEnabled,
            appliesLive: appliesLive,
            current: { $0[keyPath: slot] },
            install: { coordinator, instance, channel in
                let service = make(instance, channel)
                coordinator[keyPath: slot] = service
                return service
            },
            clear: { $0[keyPath: slot] = nil },
            releasesSlotOnChannelLoss: releasesSlotOnChannelLoss,
            onChannelLost: onChannelLost,
            afterAccept: afterAccept)
    }

    /// A framed channel paired with the data port its service serves one
    /// transfer at a time.
    ///
    /// The generic constraint is the pairing: a channel only earns a data port
    /// if its service can take a raw descriptor off the accepting thread.
    static func streamingChannel<Service: VsockFeatureService & VsockDataConnectionAccepting>(
        name: String,
        port: UInt32,
        dataPort: UInt32,
        dataSink: KeyPath<VsockFeatureCoordinator, VsockDataConnectionSink>,
        requirement: FeatureChannelRequirement,
        isEnabled: @escaping @MainActor (VMConfiguration) -> Bool,
        appliesLive: @escaping @MainActor (VMConfiguration) -> Bool = { _ in true },
        slot: ReferenceWritableKeyPath<VsockFeatureCoordinator, Service?>,
        releasesSlotOnChannelLoss: Bool = false,
        onChannelLost: (@MainActor (VMInstance) -> Void)? = nil,
        afterAccept: (@MainActor (VMInstance) -> Void)? = nil,
        make: @escaping @MainActor (VMInstance, VsockChannel) -> Service
    ) -> VsockFeatureDescriptor {
        VsockFeatureDescriptor(
            name: name,
            port: port,
            data: DataPort(port: dataPort, sink: dataSink),
            requirement: requirement,
            isEnabled: isEnabled,
            appliesLive: appliesLive,
            current: { $0[keyPath: slot] },
            install: { coordinator, instance, channel in
                let service = make(instance, channel)
                coordinator[keyPath: slot] = service
                coordinator[keyPath: dataSink].set(service)
                return service
            },
            clear: { coordinator in
                coordinator[keyPath: slot] = nil
                coordinator[keyPath: dataSink].set(nil)
            },
            releasesSlotOnChannelLoss: releasesSlotOnChannelLoss,
            onChannelLost: onChannelLost,
            afterAccept: afterAccept)
    }
}

/// The four channels a session serves.
///
/// Static because a descriptor holds nothing: the table is the same for
/// every VM, and every session drives it through its own coordinator.
@MainActor
extension VsockFeatureDescriptor {
    /// Every vsock channel a session serves, in the order a session installs
    /// them and a live edit applies them.
    static let all: [VsockFeatureDescriptor] = [control, log, clipboard, drop]

    static let control = channel(
        name: "control",
        port: KernovaVsockPort.control,
        // No admission check: every feature port is gated on the handshake this
        // channel carries, so gating this one would deadlock the session.
        requirement: nil,
        // Always installed, whatever the feature toggles say — which also
        // leaves a live edit nothing to change here.
        isEnabled: { _ in true },
        appliesLive: { _ in false },
        slot: \.control,
        onChannelLost: { instance in
            // The agent went away mid-session. Re-arm the same grace clock the
            // post-start path uses, so a channel that never comes back
            // escalates to `.expectedMissing` instead of spinning at
            // `.connecting` for the rest of the session.
            instance.startAgentPostStartWatchdog()
        },
        afterAccept: { instance in
            // Any accepted channel that never completes its Hello is on a
            // clock: an agent that connects but cannot handshake (a
            // half-finished update) is exactly when the reinstall affordance is
            // wanted. Idempotent; the Hello cancels it.
            instance.startAgentPostStartWatchdog()
        },
        make: { instance, channel in instance.makeControlService(for: channel) })

    static let log = channel(
        name: "log",
        port: KernovaVsockPort.log,
        requirement: FeatureChannelRequirement.none,
        isEnabled: { $0.agentLogForwardingEnabled },
        slot: \.log,
        // Nothing reads a settled log service, so holding a dead channel until
        // the next accept would be pure retention.
        releasesSlotOnChannelLoss: true,
        make: { instance, channel in
            VsockGuestLogService(channel: channel, label: instance.name)
        })

    static let clipboard = streamingChannel(
        name: "clipboard",
        port: KernovaVsockPort.clipboard,
        dataPort: KernovaVsockPort.clipboardData,
        dataSink: \.clipboardDataSink,
        requirement: .clipboardStreaming,
        isEnabled: { $0.clipboardSharingEnabled },
        appliesLive: { $0.guestOS == .macOS },
        slot: \.clipboard,
        // The slot is kept on channel loss: a settled service's materialized
        // representations stay servable, and the clipboard window reads its
        // buffer through `ClipboardServicing`.
        make: { instance, channel in
            makeClipboardService(for: instance, channel: channel)
        })

    static let drop = streamingChannel(
        name: "drop",
        port: KernovaVsockPort.drop,
        dataPort: KernovaVsockPort.dropData,
        dataSink: \.dropDataSink,
        requirement: .dropFiles,
        isEnabled: { $0.dropFilesEnabled },
        slot: \.drop,
        // The slot is kept on channel loss too: the settled service's
        // `isConnected == false` already refuses the display gesture.
        make: { instance, channel in
            VsockDropService(
                channel: channel, label: instance.name, reporter: instance.clipboardTransfers)
        })

    /// Builds the clipboard service for one accepted channel, wired to the VM's
    /// transfer reporter, its live paste ceiling, and the host-pasteboard hooks
    /// that keep a stale promised write from outliving the offer behind it.
    private static func makeClipboardService(
        for instance: VMInstance, channel: VsockChannel
    ) -> VsockClipboardService {
        // Read through the instance at each budget check, so a Settings change
        // lands on the live session without restarting the service.
        let service = VsockClipboardService(
            channel: channel, label: instance.name, reporter: instance.clipboardTransfers,
            maxPasteBytes: { [weak instance] in
                instance?.effectiveClipboardMaxPasteBytes ?? ClipboardPasteLimit.defaultBytes
            })
        let publisher = instance.hostClipboardPublisher
        service.hostPasteboardHoldsOurWrite = { publisher.pasteboardHoldsLastWrite }
        service.retractStaleHostWrite = { [weak instance] in
            // With passthrough on, the newer offer's automatic re-publish is
            // what supersedes the stale write; retracting too would only flash
            // an empty pasteboard and a Copy-to-Mac hint for a button
            // passthrough hides.
            guard let instance, instance.sessionContext?.clipboardPassthroughCoordinator == nil
            else { return false }
            return publisher.retractPromisedWrite()
        }
        return service
    }
}

/// One session's vsock feature channels: the listeners it installs, the
/// services behind them, and the live-policy edits that move both.
///
/// Created with a ``VMSessionContext`` and released with it, so the service
/// slots below cannot outlive the `VZVirtualMachine` whose socket device the
/// listeners are bound to. The admission gate and the two data sinks are the
/// VM's and outlive every session: the accept path reads them from whatever
/// queue VZ delivers on, so nothing there may reach this main-actor type.
@MainActor
@Observable
final class VsockFeatureCoordinator {
    private static let logger = Logger(
        subsystem: "app.kernova", category: "VsockFeatureCoordinator")

    /// The VM this session belongs to, whose configuration the descriptors read
    /// and whose reporters and publishers the services are wired to.
    ///
    /// Weak because the instance owns the context that owns this.
    @ObservationIgnored weak var instance: VMInstance?

    // MARK: - Instance-owned hand-offs

    /// Where the feature listeners read admission verdicts, off the main actor.
    @ObservationIgnored private let admissionGate: VsockAdmissionGate

    /// Where the clipboard data listener lands each accepted transfer
    /// connection.
    @ObservationIgnored fileprivate let clipboardDataSink: VsockDataConnectionSink

    /// Where the drop data listener lands each accepted item connection.
    @ObservationIgnored fileprivate let dropDataSink: VsockDataConnectionSink

    // MARK: - Service slots

    /// The always-on control channel's service, replaced by every reconnect.
    var control: VsockControlService?

    /// Forwards guest log records for as long as its channel lives.
    var log: VsockGuestLogService?

    /// The macOS guest's clipboard transport; the SPICE one lives on
    /// ``VMSessionContext/clipboardService``.
    var clipboard: VsockClipboardService?

    /// Serves files dropped on this VM's display; populated once the guest
    /// agent's drop client connects.
    var drop: VsockDropService?

    // MARK: - Initializer

    init(
        instance: VMInstance,
        admissionGate: VsockAdmissionGate,
        clipboardDataSink: VsockDataConnectionSink,
        dropDataSink: VsockDataConnectionSink
    ) {
        self.instance = instance
        self.admissionGate = admissionGate
        self.clipboardDataSink = clipboardDataSink
        self.dropDataSink = dropDataSink
    }

    /// The service currently serving `descriptor`'s channel, type-erased.
    func service(for descriptor: VsockFeatureDescriptor) -> (any VsockFeatureService)? {
        descriptor.current(self)
    }

    // MARK: - Listener hosts

    /// Every listener a session running `configuration` installs.
    func listenerHosts(for configuration: VMConfiguration, sessionID: UUID)
        -> [VsockListenerHost]
    {
        VsockFeatureDescriptor.all
            .filter { $0.isEnabled(configuration) }
            .flatMap { makeHosts(for: $0, sessionID: sessionID) }
    }

    /// One channel's listeners: the framed port first, then the data port that
    /// moves with it.
    func makeHosts(for descriptor: VsockFeatureDescriptor, sessionID: UUID)
        -> [VsockListenerHost]
    {
        // Nothing on the accept path may reach this main-actor type, so the
        // admission closure captures the gate itself.
        var shouldAdmit: VsockListenerHost.ShouldAdmit?
        if let requirement = descriptor.requirement {
            let gate = admissionGate
            shouldAdmit = { gate.admission(for: requirement) }
        }
        var hosts = [
            VsockListenerHost(port: descriptor.port, shouldAdmit: shouldAdmit) {
                [weak self] channel in
                guard let self else {
                    channel.close()
                    return
                }
                self.accept(channel, as: descriptor, sessionID: sessionID)
            }
        ]
        if let data = descriptor.data {
            let sink = self[keyPath: data.sink]
            hosts.append(
                VsockListenerHost(
                    port: data.port, shouldAdmit: shouldAdmit,
                    onAcceptFd: { fd in sink.accept(fd: fd) }))
        }
        return hosts
    }

    // MARK: - Accept

    /// Serves one accepted channel — the whole ritual, written once for every
    /// feature.
    ///
    /// The session identity and the feature's own setting are re-read here
    /// rather than captured: the accept ran on the VM's queue and this hand-off
    /// is a main-actor hop behind it, so a toggle-off or a teardown landing in
    /// between has already stopped the service and unbound the port, and this
    /// connection must not put either back.
    func accept(
        _ channel: VsockChannel, as descriptor: VsockFeatureDescriptor, sessionID: UUID
    ) {
        guard let instance, instance.liveSessionID == sessionID,
            descriptor.isEnabled(instance.configuration)
        else {
            channel.close()
            return
        }
        // Replace any prior service from a previous reconnect. `stop()` is
        // terminal and calls nobody back, so the settle below never fires for
        // the service being displaced.
        descriptor.current(self)?.stop()
        let service = descriptor.install(self, instance, channel)
        // The one place a channel-loss reaction is wired. The identity check
        // keeps a late callback from acting on a successor this path has
        // already installed — for the control channel it can only ever hold,
        // since a replacement stops the service it displaces first.
        service.onChannelLost = { [weak self, weak service] in
            guard let self, let service, descriptor.current(self) === service else { return }
            if descriptor.releasesSlotOnChannelLoss { descriptor.clear(self) }
            if let instance = self.instance { descriptor.onChannelLost?(instance) }
        }
        service.start()
        descriptor.afterAccept?(instance)
    }

    // MARK: - Teardown

    /// Settles one channel: its service stops, its slot empties, and its data
    /// sink forgets the service it was pointed at.
    func settle(_ descriptor: VsockFeatureDescriptor) {
        descriptor.current(self)?.stop()
        descriptor.clear(self)
    }

    /// Settles every channel and withdraws admission.
    ///
    /// The gate is cleared even though a stopped control service clears it
    /// itself, so a service torn down before it ever published is covered too.
    func stopAll() {
        for descriptor in VsockFeatureDescriptor.all { settle(descriptor) }
        admissionGate.clear()
    }

    // MARK: - Live Policy

    /// The live-policy application in flight, chained so a second toggle
    /// arriving before the first finishes runs after it rather than
    /// interleaving with it.
    ///
    /// Per session, so an edit made to one never queues behind a previous
    /// session's chain — nor lands on a successor's listeners, which the
    /// chain's own per-step liveness check refuses.
    @ObservationIgnored var livePolicyApplication: Task<Void, Never>?

    /// Reacts to a configuration edit on a running VM: moves the listeners the
    /// edit changed and pushes the guest agent a fresh `PolicyUpdate`.
    ///
    /// The ordering around that frame is the protocol invariant. A listener the
    /// guest is about to be told about goes up *before* it, because the frame
    /// wakes the guest's parked reconnect loop at once
    /// (`VsockGuestClient.resume()`) and a redial that beats its listener is
    /// refused and costs the guest a full retry interval. One being withdrawn
    /// comes down *after* it, because tearing a listener down while the guest
    /// still thinks the feature is on makes it see EOF and pound the host with
    /// reconnects until the policy arrives.
    func applyLivePolicy(
        oldConfig: VMConfiguration, newConfig: VMConfiguration, on session: VMSession
    ) {
        let changed = VsockFeatureDescriptor.all.filter {
            $0.isEnabled(oldConfig) != $0.isEnabled(newConfig)
        }
        // Gated on what changed, not on what applies: a clipboard edit a Linux
        // guest cannot take live still owes its agent the policy frame below.
        guard !changed.isEmpty, let instance else { return }
        let applying = changed.filter { $0.appliesLive(newConfig) }
        let installing = applying.filter { $0.isEnabled(newConfig) }
        let withdrawing = applying.filter { !$0.isEnabled(newConfig) }
        let snapshot = instance.agentPolicySnapshot(for: newConfig)
        let label = instance.name
        let sessionID = session.id

        // Captured weakly so a chain still draining cannot hold a torn-down
        // session's services — and the `VZVirtualMachine` behind them — alive.
        livePolicyApplication = Task { [weak self, previous = livePolicyApplication] in
            await previous?.value
            for descriptor in installing {
                guard let live = self, live.isLive(session) else { return }
                await live.applyLive(
                    descriptor, enabled: true, on: session, sessionID: sessionID)
            }

            guard let live = self, live.isLive(session) else { return }
            // The control service is nil in the window between accepting a
            // connection and the guest's Hello — the next Hello-driven send
            // catches that up.
            live.control?.sendPolicyUpdate(snapshot)

            for descriptor in withdrawing {
                guard let live = self, live.isLive(session) else { return }
                await live.applyLive(
                    descriptor, enabled: false, on: session, sessionID: sessionID)
            }

            guard let live = self, live.isLive(session) else { return }
            Self.logger.notice(
                "Applied live policy for '\(label, privacy: .public)' (logForwarding=\(newConfig.agentLogForwardingEnabled, privacy: .public), clipboard=\(newConfig.clipboardSharingEnabled, privacy: .public), dropFiles=\(newConfig.dropFilesEnabled, privacy: .public))"
            )
        }
    }

    /// Whether this coordinator still belongs to the live session, and that
    /// session is still `session`.
    ///
    /// Every hop hands main back, so the chain re-asks this before each step: a
    /// teardown landing in between has already queued its unbind, and a
    /// *successor* session must have neither listeners installed behind it nor
    /// its own services torn down by an edit belonging to a session already
    /// gone.
    private func isLive(_ session: VMSession) -> Bool {
        guard let context = instance?.sessionContext, context.vsock === self else { return false }
        return context.session === session
    }

    /// Installs or withdraws one channel's ports on a running VM.
    ///
    /// A channel and its data port move in one hop: a data port outliving the
    /// channel port that admits transfers onto it would accept a transfer no
    /// service is left to serve. The install is an idempotent reinstall —
    /// `attach` rebinds a port before releasing the host it displaces, so no
    /// accept can land on a dead delegate.
    func applyLive(
        _ descriptor: VsockFeatureDescriptor, enabled: Bool,
        on installer: any VsockListenerInstalling, sessionID: UUID
    ) async {
        if enabled {
            await installer.attach(makeHosts(for: descriptor, sessionID: sessionID))
        } else {
            settle(descriptor)
            await installer.detach(ports: descriptor.ports)
        }
    }
}
