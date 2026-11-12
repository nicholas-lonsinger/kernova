import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaLogging
import KernovaTransferProgress

/// A realizable network attachment for a live VM, as recovery plans it.
package enum NetworkAttachmentPlan: Equatable, Sendable {
    /// The system NAT attachment — the NAT mode in an unentitled build.
    case nat
    case bridged(String)
    /// An app-managed vmnet network — Host Only, and NAT in an
    /// entitled build.
    case vmnet(VmnetNetworkSelection)

    /// Where a Bridged choice attaches while its interface can't be bridged:
    /// the VM's own NAT network. No other guest joins it, so it adds no
    /// guest-to-guest reach, and no VM sharing this one's MAC address can be
    /// on it (``VMMACAddressRegistry`` compares the configured network, which
    /// for Bridged is not this one).
    package static let bridgedFallback = NetworkAttachmentPlan.vmnet(
        VmnetNetworkSelection(kind: .nat, membership: .isolated))

    /// The app-managed network this plan attaches to, `nil` for plans vmnet
    /// does not back.
    var vmnetSelection: VmnetNetworkSelection? {
        guard case .vmnet(let selection) = self else { return nil }
        return selection
    }
}

/// A live VM's network device as attachment recovery last reported it.
package enum NetworkAttachmentState: Equatable, Sendable {
    case attached(NetworkAttachmentPlan)
    /// No attachment; recovery is waiting to reattach.
    case detached
}

/// The network the user chose for a VM, as attachment recovery needs it.
package struct NetworkChoice: Equatable {
    package let joinedNetwork: VMJoinedNetwork
    /// The persisted bridged interface, `nil` for Automatic.
    let bridgedInterfaceIdentifier: String?

    /// The plan this choice attaches by on the host as it is now — what a
    /// boot builds (`holding` nil) and what recovery keeps a live device on
    /// (`holding` the device's current plan). `nil` only when this build
    /// cannot attach the choice.
    ///
    /// Bridged attaches over its interface while the host offers it
    /// (``BridgedInterfaceSelection/interface(persisted:held:available:primary:)``)
    /// and otherwise to ``NetworkAttachmentPlan/bridgedFallback`` — never over
    /// another interface, whose network the user did not choose.
    package func plan(
        entitlements: EntitlementService, interfaces: any BridgedInterfaceProviding,
        holding held: NetworkAttachmentPlan?
    ) -> NetworkAttachmentPlan? {
        guard let realization = entitlements.realization(of: joinedNetwork) else { return nil }
        switch realization {
        case .systemNAT:
            return .nat
        case .vmnet(let selection):
            return .vmnet(selection)
        case .bridged:
            let heldInterface: String? = if case .bridged(let identifier)? = held { identifier } else { nil }
            let interface = BridgedInterfaceSelection.interface(
                persisted: bridgedInterfaceIdentifier, held: heldInterface,
                available: interfaces.interfaces().map(\.identifier),
                primary: bridgedInterfaceIdentifier == nil ? interfaces.primaryInterfaceIdentifier() : nil)
            return interface.map(NetworkAttachmentPlan.bridged) ?? .bridgedFallback
        }
    }
}

extension VMConfiguration {
    /// The network the user chose, as attachment recovery consumes it; `nil`
    /// when the VM has no network device.
    package var networkChoice: NetworkChoice? {
        joinedNetwork.map {
            NetworkChoice(joinedNetwork: $0, bridgedInterfaceIdentifier: bridgedInterfaceIdentifier)
        }
    }
}

/// A live VM's network device, as attachment recovery drives it.
@MainActor
package protocol NetworkDeviceControlling: AnyObject {
    /// The plan the device's current attachment realizes, `nil` while detached.
    var currentPlan: NetworkAttachmentPlan? { get }
    /// Realizes `plan` on the device; applying a vmnet plan makes the VM a
    /// member of that network. Returns `false` when the host cannot provide it
    /// right now — the bridge interface vanished since resolution, or the
    /// vmnet network is not materialized.
    func apply(_ plan: NetworkAttachmentPlan) -> Bool
    func detach()
    /// The framework nil'd the live attachment ahead of its disconnect
    /// callback; reflect that.
    func attachmentWasDisconnected()
}

/// Host link-change events, as attachment recovery consumes them.
@MainActor
package protocol NetworkLinkObserving: AnyObject {
    /// Starts delivering link-change events to `onChange` until `stop()`.
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
}

/// Keeps one VM session's live network attachment realizing the mode the user
/// chose — across VZ's attachment-disconnect callback, a boot or restore that
/// came up detached, host link changes, and live mode/interface edits.
///
/// Recovery only narrows exposure (docs/NETWORKING.md): after each reconcile
/// the device is on the plan ``NetworkChoice/plan(entitlements:interfaces:holding:)``
/// answers, or detached while that plan can't attach. A Bridged VM whose
/// interface is gone is on its own NAT network until the interface returns,
/// never on another interface's network.
///
/// Created by the bring-up alongside the `VZVirtualMachine`. `activate()` is
/// deferred until the session first reaches `.running`, and reconciliation is
/// gated to running and live-paused sessions through `isEligible` — Kernova's
/// choice to keep attachment churn away from boot, restore, and state saves;
/// runtime attachment swaps themselves carry no VZ state precondition.
@MainActor
package final class NetworkAttachmentCoordinator {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "NetworkAttachmentCoordinator")

    /// Reattempt cadence, in seconds, after a failed attach; escalated while
    /// attaches keep failing, reset by each fresh trigger. Bounded: once
    /// exhausted, recovery waits for the next link change or disconnect. It
    /// exists because `VZBridgedNetworkInterface.networkInterfaces` can lag
    /// the dynamic-store event announcing the interface.
    static let defaultRetryDelays: [TimeInterval] = [1, 2, 4, 8]

    /// A disconnect this soon, in seconds, after an attach attempt is VZ
    /// reporting that attempt failed — a live attachment set reports failure
    /// only asynchronously, through another disconnect callback — so it routes
    /// through the retry ladder instead of reattaching immediately, which
    /// would spin at VZ's failure cadence.
    static let disconnectBurstWindow: TimeInterval = 1

    /// Reattempt cadence, in seconds, after a failed vmnet materialization
    /// while a Host Only session sits detached. The NetworkSharing daemon
    /// publishes no recovery notification, so attempts pace themselves —
    /// bounded like the attach ladder; a later reconcile trigger re-enters.
    static let defaultVmnetRematerializeDelays: [TimeInterval] = [8, 16, 32]

    private let vmName: String
    private let device: any NetworkDeviceControlling
    private let interfaces: any BridgedInterfaceProviding
    private let linkObserver: any NetworkLinkObserving
    private let vmnetNetworks: VmnetSessionNetworks
    /// What this build authorizes, which decides how each network the user
    /// chooses is attached (``EntitlementService/realization(of:)``).
    private let entitlements: EntitlementService
    private let retryDelays: [TimeInterval]
    private let vmnetRematerializeDelays: [TimeInterval]
    private let clock: any EngineClock
    private var lastAttachAttemptAt: EngineInstant?
    private let isEligible: @MainActor () -> Bool
    private let choice: @MainActor () -> NetworkChoice?
    private let onAttachmentChange: @MainActor (NetworkAttachmentState?) -> Void

    /// What recovery last reported for the device, `nil` while it reports
    /// nothing — before the first reconcile, or with no network chosen.
    private var reported: NetworkAttachmentState?

    /// `true` while the device is detached and recovery is waiting to
    /// reattach.
    var isPending: Bool { reported == .detached }

    private var isActive = false
    private var retryTask: Task<Void, Never>?
    private var nextRetryIndex = 0
    private var vmnetMaterializationTask: Task<Void, Never>?
    /// The network the in-flight materialization serves — a live switch to
    /// another vmnet network must supersede it, not be swallowed by the
    /// single-flight guard.
    private var vmnetMaterializationSelection: VmnetNetworkSelection?
    /// Identifies the current materialization task, so a superseded
    /// (cancelled) task resuming late cannot clear its replacement's handle.
    private var vmnetMaterializationGeneration = 0

    package init(
        vmName: String,
        device: any NetworkDeviceControlling,
        interfaces: any BridgedInterfaceProviding,
        linkObserver: any NetworkLinkObserving,
        vmnetNetworks: VmnetSessionNetworks,
        entitlements: EntitlementService,
        retryDelays: [TimeInterval] = NetworkAttachmentCoordinator.defaultRetryDelays,
        vmnetRematerializeDelays: [TimeInterval] =
            NetworkAttachmentCoordinator.defaultVmnetRematerializeDelays,
        clock: any EngineClock = makePlatformEngineClock(),
        isEligible: @escaping @MainActor () -> Bool,
        choice: @escaping @MainActor () -> NetworkChoice?,
        onAttachmentChange: @escaping @MainActor (NetworkAttachmentState?) -> Void
    ) {
        self.vmName = vmName
        self.device = device
        self.interfaces = interfaces
        self.linkObserver = linkObserver
        self.vmnetNetworks = vmnetNetworks
        self.entitlements = entitlements
        self.retryDelays = retryDelays
        self.vmnetRematerializeDelays = vmnetRematerializeDelays
        self.clock = clock
        self.isEligible = isEligible
        self.choice = choice
        self.onAttachmentChange = onAttachmentChange
    }

    /// Starts link observation and reconciles once. Idempotent — a hot resume
    /// re-activates the same session and just re-reconciles.
    func activate() {
        if !isActive {
            isActive = true
            linkObserver.start { [weak self] in self?.hostLinkChanged() }
        }
        reconcile(trigger: "activate")
    }

    package func stop() {
        isActive = false
        linkObserver.stop()
        cancelRetry()
        vmnetMaterializationTask?.cancel()
        vmnetMaterializationTask = nil
        vmnetMaterializationSelection = nil
    }

    /// VZ's attachment-disconnect callback: the framework has nil'd the
    /// attachment. Benign — it also fires on initial boot, device reset,
    /// and guest reboot — so it is never surfaced as a VM error; the answer
    /// is always to reattach.
    func attachmentWasDisconnected(error: any Error) {
        Self.logger.log(
            .warning,
            "Network attachment for '\(self.vmName, privacy: .public)' disconnected: \(error.localizedDescription, privacy: .public)"
        )
        // Ahead of the guards: the framework already nil'd the attachment, and
        // the device's mirror must say so even when this session isn't
        // eligible to reattach right now.
        device.attachmentWasDisconnected()
        guard isActive, isEligible() else { return }
        let isFailedAttachReport =
            lastAttachAttemptAt.map { clock.seconds(since: $0) < Self.disconnectBurstWindow } ?? false
        if isFailedAttachReport {
            // VZ has already nil'd the attachment; reflect that and let the
            // ladder pace the next attempt rather than reattaching in lockstep
            // with a persistently failing attach.
            reportDevice()
            if retryTask == nil { scheduleRetry() }
            return
        }
        reconcile(trigger: "disconnect")
    }

    /// A live mode or interface edit reached the persisted configuration.
    func configurationChanged() {
        guard isActive else { return }
        reconcile(trigger: "configuration change")
    }

    private func hostLinkChanged() {
        guard isActive else { return }
        reconcile(trigger: "host link change")
    }

    private func reconcile(trigger: String, resetBackoff: Bool = true) {
        cancelRetry()
        guard isEligible() else {
            // A saving or otherwise ineligible session: drop the trigger —
            // activation at the next `.running` re-reconciles.
            return
        }
        if resetBackoff { nextRetryIndex = 0 }

        guard let choice = choice() else {
            // The picker disables None while the VM runs — a session losing its
            // network device mid-flight has no supported path here.
            Self.logger.log(
                .warning,
                "Network reconcile for '\(self.vmName, privacy: .public)' found no network choice — leaving the attachment alone"
            )
            report(nil)
            return
        }

        let desired = choice.plan(entitlements: entitlements, interfaces: interfaces, holding: device.currentPlan)
        if device.currentPlan != desired {
            if let desired {
                lastAttachAttemptAt = clock.now
                if device.apply(desired) {
                    Self.logger.log(
                        .notice,
                        "Attached network for '\(self.vmName, privacy: .public)' (\(String(describing: desired), privacy: .public), on \(trigger, privacy: .public))"
                    )
                } else {
                    Self.logger.log(
                        .warning,
                        "Could not attach network for '\(self.vmName, privacy: .public)' (\(String(describing: desired), privacy: .public) refused, on \(trigger, privacy: .public))"
                    )
                }
            }
            // A refused apply leaves the previous attachment live, and a choice
            // this build can't attach leaves whatever was there: either is a
            // network the user didn't choose, so the device detaches
            // (docs/NETWORKING.md).
            if device.currentPlan != desired, device.currentPlan != nil { device.detach() }
        }

        reportDevice()
        if isPending {
            scheduleRetry()
            if let selection = desired?.vmnetSelection { ensureVmnetMaterialization(of: selection) }
        }
    }

    /// Drives the app's vmnet network toward materialized while a session in
    /// a vmnet-backed mode sits detached, reconciling the moment it is ready —
    /// the wake-up signal ladder exhaustion would otherwise leave missing,
    /// since host link changes are a bridged signal and a detached device
    /// fires no disconnects.
    private func ensureVmnetMaterialization(of selection: VmnetNetworkSelection) {
        if vmnetMaterializationTask != nil {
            guard vmnetMaterializationSelection != selection else { return }
            vmnetMaterializationTask?.cancel()
            vmnetMaterializationTask = nil
        }
        vmnetMaterializationSelection = selection
        vmnetMaterializationGeneration += 1
        let generation = vmnetMaterializationGeneration
        vmnetMaterializationTask = Task {
            [weak self, clock, vmnetNetworks, vmnetRematerializeDelays] in
            var attempt = 0
            while !Task.isCancelled {
                guard let coordinator = self, coordinator.isActive, coordinator.isPending else {
                    break
                }
                if let hold = await vmnetNetworks.materializeNetwork(for: selection) {
                    self?.clearMaterializationTask(generation: generation)
                    // The reconcile's apply joins the network; one the choice
                    // has since left goes with the hold.
                    withExtendedLifetime(hold) {
                        if let coordinator = self, coordinator.isActive {
                            coordinator.reconcile(trigger: "vmnet network materialized")
                        }
                    }
                    return
                }
                guard attempt < vmnetRematerializeDelays.count else { break }
                do { try await clock.sleep(for: vmnetRematerializeDelays[attempt]) } catch { break }
                attempt += 1
            }
            self?.clearMaterializationTask(generation: generation)
        }
    }

    /// Clears the in-flight materialization handle — only if it still belongs
    /// to the task of `generation`, so a superseded (cancelled) task resuming
    /// late cannot drop its replacement's handle.
    private func clearMaterializationTask(generation: Int) {
        guard vmnetMaterializationGeneration == generation else { return }
        vmnetMaterializationTask = nil
        vmnetMaterializationSelection = nil
    }

    private func scheduleRetry() {
        guard nextRetryIndex < retryDelays.count else {
            ladderExhausted()
            return
        }
        let delay = retryDelays[nextRetryIndex]
        nextRetryIndex += 1
        retryTask = clock.schedule(after: delay) { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.reconcile(trigger: "retry", resetBackoff: false)
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    private func ladderExhausted() {
        guard let choice = choice(),
            let selection = choice.plan(
                entitlements: entitlements, interfaces: interfaces, holding: device.currentPlan)?.vmnetSelection
        else { return }
        Self.logger.log(
            .warning,
            "Network attachment for '\(self.vmName, privacy: .public)' exhausted its ladder on the \(selection.logDescription, privacy: .public) network"
        )
    }

    /// Reports the plan the device is on, or that it is detached.
    private func reportDevice() {
        report(device.currentPlan.map(NetworkAttachmentState.attached) ?? .detached)
    }

    private func report(_ state: NetworkAttachmentState?) {
        guard state != reported else { return }
        reported = state
        Self.logger.log(
            .notice,
            "Network attachment for '\(self.vmName, privacy: .public)' is \(state.map { String(describing: $0) } ?? "untracked", privacy: .public)"
        )
        onAttachmentChange(state)
    }

    #if DEBUG
    /// The in-flight backoff retry, for event-driven test waits.
    var retryTaskForTesting: Task<Void, Never>? { retryTask }
    /// The in-flight vmnet materialization, for event-driven test waits.
    var vmnetMaterializationTaskForTesting: Task<Void, Never>? { vmnetMaterializationTask }
    #endif
}
