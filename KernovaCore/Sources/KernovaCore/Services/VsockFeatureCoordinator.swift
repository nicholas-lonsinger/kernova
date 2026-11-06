import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaLogging

/// One vsock feature channel, described once: the port it binds, what gates
/// it, which slot on the coordinator holds its service, and what a channel
/// dying under that service means for the slot.
///
/// Every closure takes the coordinator (or the VM) as an argument instead of
/// capturing one, so a descriptor is a session-independent constant that holds
/// nothing and can never close a retain cycle over what it drives.
struct VsockFeatureDescriptor {
    /// This channel's name in test failure messages.
    let name: String

    /// The framed channel port.
    let port: UInt32

    /// The guest capability an accepted connection needs beyond the completed
    /// control handshake, or `nil` for a listener that admits unconditionally.
    let requirement: FeatureChannelRequirement?

    /// The configuration setting that turns this channel on for a macOS guest.
    let toggle: @MainActor (VMConfiguration) -> Bool

    /// Reads this channel's service slot.
    let current: @MainActor (VsockFeatureCoordinator) -> (any VsockFeatureService)?

    /// Builds the service for one accepted channel and fills the slot.
    let install:
        @MainActor (VsockFeatureCoordinator, VMInstance, VsockChannel) ->
            any VsockFeatureService

    /// Empties the slot.
    let clear: @MainActor (VsockFeatureCoordinator) -> Void

    /// Whether a channel that died under its service empties the slot too, or
    /// the settled service stays referenced until the next accept replaces it.
    let releasesSlotOnChannelLoss: Bool

    /// Whether a session running `configuration` binds this channel — the one
    /// predicate install, accept and live edit all read.
    ///
    /// Only a macOS guest's agent speaks these channels, so no other guest's
    /// session binds one, whatever its settings say.
    @MainActor
    func isEnabled(_ configuration: VMConfiguration) -> Bool {
        configuration.guestOS == .macOS && toggle(configuration)
    }
}

/// A channel's shape, building the slot accessors its service type needs
/// without a cast at the use site.
@MainActor
extension VsockFeatureDescriptor {
    /// A framed channel whose service serves that channel alone.
    static func channel<Service: VsockFeatureService>(
        name: String,
        port: UInt32,
        requirement: FeatureChannelRequirement?,
        toggle: @escaping @MainActor (VMConfiguration) -> Bool,
        slot: ReferenceWritableKeyPath<VsockFeatureCoordinator, Service?>,
        releasesSlotOnChannelLoss: Bool = false,
        make: @escaping @MainActor (VMInstance, VsockChannel) -> Service
    ) -> VsockFeatureDescriptor {
        VsockFeatureDescriptor(
            name: name,
            port: port,
            requirement: requirement,
            toggle: toggle,
            current: { $0[keyPath: slot] },
            install: { coordinator, instance, channel in
                let service = make(instance, channel)
                coordinator[keyPath: slot] = service
                return service
            },
            clear: { $0[keyPath: slot] = nil },
            releasesSlotOnChannelLoss: releasesSlotOnChannelLoss)
    }
}

/// The channels a session serves.
///
/// Static because a descriptor holds nothing: the table is the same for
/// every VM, and every session drives it through its own coordinator.
@MainActor
extension VsockFeatureDescriptor {
    /// Every vsock channel a session serves, in the order a session installs
    /// them and a live edit applies them.
    static let all: [VsockFeatureDescriptor] = [control, log]

    static let control = channel(
        name: "control",
        port: KernovaVsockPort.control,
        // No admission check: every feature port is gated on the handshake this
        // channel carries, so gating this one would deadlock the session.
        requirement: nil,
        // On in every macOS session, whatever the feature toggles say — which also
        // leaves a live edit nothing to change here.
        toggle: { _ in true },
        slot: \.control,
        make: { instance, channel in instance.makeControlService(for: channel) })

    static let log = channel(
        name: "log",
        port: KernovaVsockPort.log,
        requirement: FeatureChannelRequirement.none,
        toggle: { $0.agentLogForwardingEnabled },
        slot: \.log,
        // Nothing reads a settled log service, so holding a dead channel until
        // the next accept would be pure retention.
        releasesSlotOnChannelLoss: true,
        make: { instance, channel in
            VsockGuestLogService(channel: channel, label: instance.name)
        })
}

/// One session's vsock feature channels: the listeners it installs, the
/// services behind them, and the live-policy edits that move both.
///
/// Created with a ``VMSessionContext`` and released with it, so the service
/// slots below cannot outlive the `VZVirtualMachine` whose socket device the
/// listeners are bound to. The admission gate is the VM's and outlives every
/// session: the accept path reads it from whatever queue VZ delivers on, so
/// nothing there may reach this main-actor type.
@MainActor
@Observable
final class VsockFeatureCoordinator {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VsockFeatureCoordinator")

    /// The VM this session belongs to, whose configuration the descriptors read
    /// and whose reporters and publishers the services are wired to.
    ///
    /// Weak because the instance owns the context that owns this.
    @ObservationIgnored weak var instance: VMInstance?

    // MARK: - Instance-owned hand-offs

    /// Where the feature listeners read admission verdicts, off the main actor.
    @ObservationIgnored private let admissionGate: VsockAdmissionGate

    // MARK: - Service slots

    /// The always-on control channel's service, replaced by every reconnect.
    var control: VsockControlService?

    /// Forwards guest log records for as long as its channel lives.
    var log: VsockGuestLogService?

    // MARK: - Initializer

    init(
        instance: VMInstance,
        admissionGate: VsockAdmissionGate
    ) {
        self.instance = instance
        self.admissionGate = admissionGate
    }

    /// The service currently serving `descriptor`'s channel, type-erased.
    func service(for descriptor: VsockFeatureDescriptor) -> (any VsockFeatureService)? {
        descriptor.current(self)
    }

    // MARK: - Listeners

    /// Every listener a session running `configuration` installs.
    func listeners(for configuration: VMConfiguration, sessionID: UUID) -> [VsockListener] {
        VsockFeatureDescriptor.all
            .filter { $0.isEnabled(configuration) }
            .map { makeListener(for: $0, sessionID: sessionID) }
    }

    /// One channel's listener.
    func makeListener(for descriptor: VsockFeatureDescriptor, sessionID: UUID) -> VsockListener {
        // Nothing on the accept path may reach this main-actor type, so the
        // admission closure captures the gate itself.
        var shouldAdmit: VsockListener.ShouldAdmit?
        if let requirement = descriptor.requirement {
            let gate = admissionGate
            shouldAdmit = { gate.admission(for: requirement) }
        }
        return VsockListener(port: descriptor.port, shouldAdmit: shouldAdmit) {
            [weak self] channel in
            guard let self else {
                channel.close()
                return
            }
            self.accept(channel, as: descriptor, sessionID: sessionID)
        }
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
        // already installed.
        service.onChannelLost = { [weak self, weak service] in
            guard let self, let service, descriptor.current(self) === service else { return }
            if descriptor.releasesSlotOnChannelLoss { descriptor.clear(self) }
        }
        service.start()
    }

    // MARK: - Teardown

    /// Settles one channel: its service stops and its slot empties.
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
        oldConfig: VMConfiguration, newConfig: VMConfiguration, on session: any VMSessionOperating
    ) {
        let changed = VsockFeatureDescriptor.all.filter {
            $0.isEnabled(oldConfig) != $0.isEnabled(newConfig)
        }
        guard !changed.isEmpty, let instance else { return }
        let installing = changed.filter { $0.isEnabled(newConfig) }
        let withdrawing = changed.filter { !$0.isEnabled(newConfig) }
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
            Self.logger.log(
                .notice,
                "Applied live policy for '\(label, privacy: .public)' (logForwarding=\(newConfig.agentLogForwardingEnabled, privacy: .public))"
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
    private func isLive(_ session: any VMSessionOperating) -> Bool {
        guard let context = instance?.sessionContext, context.vsock === self else { return false }
        return context.session === session
    }

    /// Installs or withdraws one channel's port on a running VM.
    ///
    /// The install is an idempotent reinstall —
    /// `attach` rebinds a port before releasing the host it displaces, so no
    /// accept can land on a dead delegate.
    func applyLive(
        _ descriptor: VsockFeatureDescriptor, enabled: Bool,
        on installer: any VsockListenerInstalling, sessionID: UUID
    ) async {
        if enabled {
            await installer.attach([makeListener(for: descriptor, sessionID: sessionID)])
        } else {
            settle(descriptor)
            await installer.detach(ports: [descriptor.port])
        }
    }
}
