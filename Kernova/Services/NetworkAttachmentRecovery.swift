import Foundation
import KernovaKit
import SystemConfiguration
import Virtualization
import os
import vmnet

/// A realizable network attachment for a live VM, decoupled from VZ for testability.
enum NetworkAttachmentPlan: Equatable, Sendable {
    /// The system NAT attachment — Shared Network in an unentitled build.
    case nat
    case bridged(String)
    case hostOnly
    /// The app-managed vmnet shared network — Shared Network in an entitled
    /// build, where DHCP reservations back the IP display.
    case sharedVmnet

    /// The mode this plan realizes. The bridged interface is deliberately
    /// ignored: an attachment over any interface realizes Bridged.
    var realizedMode: VMNetworkMode {
        switch self {
        case .nat, .sharedVmnet: .shared
        case .bridged: .bridged
        case .hostOnly: .hostOnly
        }
    }

    func matches(_ mode: VMNetworkMode) -> Bool {
        realizedMode == mode
    }

    /// The app-managed network this plan attaches to, `nil` for plans vmnet
    /// does not back.
    var vmnetKind: VmnetNetworkKind? {
        switch self {
        case .hostOnly: .hostOnly
        case .sharedVmnet: .shared
        case .nat, .bridged: nil
        }
    }
}

/// The network the user chose for a VM, as attachment recovery needs it.
struct NetworkChoice: Equatable {
    let mode: VMNetworkMode
    /// The persisted bridged interface, `nil` for Automatic.
    let bridgedInterfaceIdentifier: String?
}

extension VMConfiguration {
    /// The network the user chose, as attachment recovery consumes it; `nil`
    /// when the VM has no network device.
    var networkChoice: NetworkChoice? {
        guard networkEnabled else { return nil }
        return NetworkChoice(mode: networkMode, bridgedInterfaceIdentifier: bridgedInterfaceIdentifier)
    }
}

/// A live VM's network device, as attachment recovery drives it.
@MainActor
protocol NetworkDeviceControlling: AnyObject {
    /// The plan the device's current attachment realizes, `nil` while detached.
    var currentPlan: NetworkAttachmentPlan? { get }
    /// Realizes `plan` on the device. Returns `false` when the host cannot
    /// provide it right now — the bridge interface vanished since resolution.
    func apply(_ plan: NetworkAttachmentPlan) -> Bool
    func detach()
    /// The framework nil'd the live attachment ahead of its disconnect
    /// callback; reflect that.
    func attachmentWasDisconnected()
}

/// The queue-side half of a live VM's network device, as the main-actor
/// handle drives it.
protocol NetworkAttachmentInstalling: Sendable {
    /// Builds an attachment on the VM's queue via `make` and installs it,
    /// calling `onBuildFailure` there when `make` finds nothing to build and
    /// the device is left detached.
    func applyNetworkAttachment(
        _ make: @escaping @Sendable () -> VZNetworkDeviceAttachment?,
        onBuildFailure: @escaping @Sendable () -> Void)
    func detachNetworkAttachment()
}

extension VMSession: NetworkAttachmentInstalling {}

/// Drives a session's network device from the main actor: feasibility is
/// answered here, synchronously, from host state and a mirror of the plan
/// last applied, while the VZ writes are forwarded to the session's queue in
/// program order and never awaited — a live attachment install reports
/// failure only asynchronously, through a later disconnect callback, so there
/// is nothing to wait for. The one queue-side outcome that reaches back is a
/// build finding nothing to install, which clears the mirror. The queue-side
/// factories re-fetch the concrete `VZBridgedNetworkInterface` by identifier
/// at each attach — a VZ interface object held across a link change is stale.
@MainActor
final class VZNetworkDeviceHandle: NetworkDeviceControlling {
    private let session: any NetworkAttachmentInstalling
    private let vmnetNetworks: any VmnetNetworkProviding

    /// The plan the device is on: what `apply`/`detach` last installed,
    /// cleared when the framework reports the attachment disconnected.
    private var appliedPlan: NetworkAttachmentPlan?

    /// Counts the applies made, so a build failure reported after a later
    /// apply has landed cannot pull the mirror backwards.
    private var appliedGeneration = 0

    init(
        session: any NetworkAttachmentInstalling,
        initialPlan: NetworkAttachmentPlan?,
        vmnetNetworks: any VmnetNetworkProviding = VmnetNetworkService.shared
    ) {
        self.session = session
        self.appliedPlan = initialPlan
        self.vmnetNetworks = vmnetNetworks
    }

    /// Classifies a live attachment back to the plan it realizes — run on the
    /// session's queue to seed `initialPlan` from the attachment the
    /// configuration build installed. A network the service no longer holds
    /// realizes nothing, so reconciliation replaces it.
    nonisolated static func plan(
        of attachment: VZNetworkDeviceAttachment, in vmnetNetworks: any VmnetNetworkProviding
    ) -> NetworkAttachmentPlan? {
        switch attachment {
        case is VZNATNetworkDeviceAttachment:
            .nat
        case let bridged as VZBridgedNetworkDeviceAttachment:
            .bridged(bridged.interface.identifier)
        case let vmnet as VZVmnetNetworkDeviceAttachment:
            switch vmnetNetworks.kind(ofNetwork: vmnet.network) {
            case .hostOnly: .hostOnly
            case .shared: .sharedVmnet
            case nil: nil
            }
        default:
            nil
        }
    }

    var currentPlan: NetworkAttachmentPlan? { appliedPlan }

    func apply(_ plan: NetworkAttachmentPlan) -> Bool {
        let make: @Sendable () -> VZNetworkDeviceAttachment?
        switch plan {
        case .nat:
            make = { VZNATNetworkDeviceAttachment() }
        case .bridged(let identifier):
            guard Self.bridgedInterface(identifier) != nil else { return false }
            make = {
                Self.bridgedInterface(identifier)
                    .map(VZBridgedNetworkDeviceAttachment.init(interface:))
            }
        case .hostOnly, .sharedVmnet:
            // Non-blocking: an unmaterialized network refuses the apply, and
            // the coordinator materializes it off-main and reconciles when
            // it's ready.
            guard let kind = plan.vmnetKind,
                vmnetNetworks.attachmentIfMaterialized(for: kind) != nil
            else { return false }
            make = { [vmnetNetworks] in vmnetNetworks.attachmentIfMaterialized(for: kind) }
        }
        appliedPlan = plan
        appliedGeneration += 1
        let generation = appliedGeneration
        session.applyNetworkAttachment(make) { [weak self] in
            Task { @MainActor in self?.buildFoundNothing(generation: generation) }
        }
        return true
    }

    /// The queue-side build of generation `generation` found nothing, so the
    /// device is detached — unless a later apply has already moved the mirror
    /// on, in which case that apply's own outcome governs.
    private func buildFoundNothing(generation: Int) {
        guard generation == appliedGeneration else { return }
        appliedPlan = nil
    }

    private nonisolated static func bridgedInterface(_ identifier: String) -> VZBridgedNetworkInterface? {
        VZBridgedNetworkInterface.networkInterfaces.first { $0.identifier == identifier }
    }

    func detach() {
        appliedPlan = nil
        session.detachNetworkAttachment()
    }

    func attachmentWasDisconnected() {
        appliedPlan = nil
    }
}

/// Host link-change events, as attachment recovery consumes them.
@MainActor
protocol NetworkLinkObserving: AnyObject {
    /// Starts delivering link-change events to `onChange` until `stop()`.
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
}

/// Observes host link changes through the SystemConfiguration dynamic store:
/// the IPv4/IPv6 global (default-route) state plus every interface's link key.
@MainActor
final class HostNetworkLinkObserver: NetworkLinkObserving {
    private static let logger = Logger(
        subsystem: "app.kernova", category: "HostNetworkLinkObserver")

    private var store: SCDynamicStore?
    /// `fileprivate` for the file-scope callout below.
    fileprivate var onChange: (() -> Void)?

    func start(onChange: @escaping @MainActor () -> Void) {
        stop()
        self.onChange = onChange

        // The store retains `self` through the context until `stop()` releases
        // the store, so a callback queued behind teardown never sees a dangling
        // pointer.
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: hostLinkObserverRetain,
            release: hostLinkObserverRelease,
            copyDescription: nil)
        guard
            let store = SCDynamicStoreCreate(
                nil, "Kernova.NetworkLinkObserver" as CFString,
                hostLinkObserverCallout,
                &context)
        else {
            Self.logger.fault("SCDynamicStoreCreate returned nil — link changes go unobserved")
            assertionFailure("SCDynamicStoreCreate returned nil")
            return
        }
        SCDynamicStoreSetNotificationKeys(
            store,
            ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] as CFArray,
            ["State:/Network/Interface/.*/Link"] as CFArray)
        SCDynamicStoreSetDispatchQueue(store, DispatchQueue.global(qos: .utility))
        self.store = store
    }

    func stop() {
        onChange = nil
        guard let store else { return }
        SCDynamicStoreSetDispatchQueue(store, nil)
        self.store = nil
    }
}

// RATIONALE (2026-08-13): `SCDynamicStore` invokes these on the store's
// dispatch queue, so they must be `nonisolated` file-scope functions, never
// closure literals formed inside the `@MainActor` class: the compiler gives
// such a literal main-actor isolation plus a dynamic check, which traps
// (`EXC_BREAKPOINT` in `dispatch_assert_queue`) the moment a real link event
// fires — observed on the first host-only VM boot, which reconfigures host
// interfaces and fires the event immediately.

private nonisolated func hostLinkObserverRetain(_ info: UnsafeRawPointer) -> UnsafeRawPointer {
    _ = Unmanaged<AnyObject>.fromOpaque(info).retain()
    return info
}

private nonisolated func hostLinkObserverRelease(_ info: UnsafeRawPointer) {
    Unmanaged<AnyObject>.fromOpaque(info).release()
}

private nonisolated func hostLinkObserverCallout(
    _: SCDynamicStore, _: CFArray, _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    let observer = Unmanaged<HostNetworkLinkObserver>.fromOpaque(info).takeUnretainedValue()
    Task { @MainActor in observer.onChange?() }
}

/// Keeps one VM session's live network attachment realizing the mode the user
/// chose — across VZ's attachment-disconnect callback, a boot or restore that
/// came up detached, host link changes, and live mode/interface edits.
///
/// Recovery narrows but never escalates: a bridged VM whose interface is gone
/// falls back within Bridged (to the default-route interface) or runs detached
/// until one returns — it never silently becomes Shared Network, and no mode
/// is ever attached that the user didn't choose (docs/NETWORKING.md).
///
/// Created by `VMInstance` alongside the `VZVirtualMachine`. `activate()` is
/// deferred until the session first reaches `.running`, and reconciliation is
/// gated to running and live-paused sessions through `isEligible` — Kernova's
/// choice to keep attachment churn away from boot, restore, and state saves;
/// runtime attachment swaps themselves carry no VZ state precondition.
@MainActor
final class NetworkAttachmentCoordinator {
    private static let logger = Logger(
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
    static let defaultDisconnectBurstWindow: TimeInterval = 1

    /// Reattempt cadence, in seconds, after a failed vmnet materialization
    /// while a Host Only session sits detached. The NetworkSharing daemon
    /// publishes no recovery notification, so attempts pace themselves —
    /// bounded like the attach ladder; a later reconcile trigger re-enters.
    static let defaultVmnetRematerializeDelays: [TimeInterval] = [8, 16, 32]

    private let vmName: String
    private let device: any NetworkDeviceControlling
    private let interfaces: any BridgedInterfaceProviding
    private let linkObserver: any NetworkLinkObserving
    private let vmnetNetworks: any VmnetNetworkProviding
    /// Whether this build realizes Shared over the app-managed vmnet network
    /// (`.sharedVmnet`) or the system NAT attachment (`.nat`). A process-wide
    /// constant, snapshotted at init.
    private let isVMNetworkingEntitled: Bool
    private let retryDelays: [TimeInterval]
    private let disconnectBurstWindow: TimeInterval
    private let vmnetRematerializeDelays: [TimeInterval]
    private let clock: any EngineClock
    private var lastAttachAttemptAt: EngineInstant?
    private let isEligible: @MainActor () -> Bool
    private let choice: @MainActor () -> NetworkChoice?
    private let onPendingChange: @MainActor (Bool) -> Void
    private let onNetworkDefectSuspected: @MainActor () -> Void

    /// `true` while the device is detached — no attachment realizes the chosen
    /// mode and recovery is waiting to reattach.
    private(set) var isPending = false

    /// The app-managed network the live device is attached to, `nil` for
    /// non-vmnet attachments and a detached device — the main-actor read
    /// `VMInstance.mayHoldAttachment(on:)` uses now that the device object
    /// itself lives on the session's queue.
    var appliedVmnetKind: VmnetNetworkKind? { device.currentPlan?.vmnetKind }
    private var isActive = false
    private var retryTask: Task<Void, Never>?
    private var nextRetryIndex = 0
    private var vmnetMaterializationTask: Task<Void, Never>?
    /// The kind the in-flight materialization serves — a live mode switch to
    /// the other vmnet-backed mode must supersede it, not be swallowed by the
    /// single-flight guard.
    private var vmnetMaterializationKind: VmnetNetworkKind?
    /// Identifies the current materialization task, so a superseded
    /// (cancelled) task resuming late cannot clear its replacement's handle.
    private var vmnetMaterializationGeneration = 0
    /// Whether this pending episode already reported the network defective —
    /// once per episode bounds the recreate churn of a persistently failing
    /// attachment, a still-defective recreate included. Reset by a fresh
    /// episode, and by the chosen mode resolving onto a different network,
    /// whose own defect this session has yet to report.
    private var didReportNetworkDefect = false

    /// The kind ``ladderExhausted()`` last reported, before checking that the
    /// session still resolves onto it.
    private var reportedDefectiveVmnetKind: VmnetNetworkKind?

    /// The network the chosen mode resolved to at the last reconcile, so a
    /// change of network can retire what was claimed about the previous one.
    private var resolvedVmnetKind: VmnetNetworkKind?

    /// The app-managed network this session believes is defective, `nil` when
    /// it suspects none — the outstanding claim
    /// `VMInstance.suspectsDefectiveNetwork(on:)` publishes for the library's
    /// arbiter to read.
    ///
    /// Derived rather than stored, so it stands only while the session is
    /// still on the network it reported: a live switch to another mode leaves
    /// the claim behind with no attach to withdraw it, and a mode that
    /// resolves to nothing at all never reaches `setPending(false)`.
    /// Attaching withdraws it, and so does the recreate that answers it.
    /// Nothing queues it, so an arbiter that refuses the recreate today
    /// re-derives the claim on its next pass.
    var suspectedDefectiveVmnetKind: VmnetNetworkKind? {
        guard let reportedDefectiveVmnetKind,
            choice().flatMap(resolvePlan(for:))?.vmnetKind == reportedDefectiveVmnetKind
        else { return nil }
        return reportedDefectiveVmnetKind
    }

    init(
        vmName: String,
        device: any NetworkDeviceControlling,
        interfaces: any BridgedInterfaceProviding,
        linkObserver: any NetworkLinkObserving,
        vmnetNetworks: (any VmnetNetworkProviding)? = nil,
        isVMNetworkingEntitled: Bool = EntitlementService.shared.hasVMNetworking,
        retryDelays: [TimeInterval] = NetworkAttachmentCoordinator.defaultRetryDelays,
        disconnectBurstWindow: TimeInterval = NetworkAttachmentCoordinator.defaultDisconnectBurstWindow,
        vmnetRematerializeDelays: [TimeInterval] =
            NetworkAttachmentCoordinator.defaultVmnetRematerializeDelays,
        clock: any EngineClock = makePlatformEngineClock(),
        isEligible: @escaping @MainActor () -> Bool = { true },
        choice: @escaping @MainActor () -> NetworkChoice?,
        onPendingChange: @escaping @MainActor (Bool) -> Void,
        onNetworkDefectSuspected: @escaping @MainActor () -> Void
    ) {
        self.vmName = vmName
        self.device = device
        self.interfaces = interfaces
        self.linkObserver = linkObserver
        self.vmnetNetworks = vmnetNetworks ?? VmnetNetworkService.shared
        self.isVMNetworkingEntitled = isVMNetworkingEntitled
        self.retryDelays = retryDelays
        self.disconnectBurstWindow = disconnectBurstWindow
        self.vmnetRematerializeDelays = vmnetRematerializeDelays
        self.clock = clock
        self.isEligible = isEligible
        self.choice = choice
        self.onPendingChange = onPendingChange
        self.onNetworkDefectSuspected = onNetworkDefectSuspected
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

    func stop() {
        isActive = false
        linkObserver.stop()
        cancelRetry()
        vmnetMaterializationTask?.cancel()
        vmnetMaterializationTask = nil
        vmnetMaterializationKind = nil
        // A torn-down session claims nothing: its suspicion must not outlive it
        // and drive a recreate on behalf of a VM that is gone.
        reportedDefectiveVmnetKind = nil
    }

    /// VZ's attachment-disconnect callback: the framework has nil'd the
    /// attachment. Benign by design — it also fires on initial boot, device
    /// reset, and guest reboot — so it is never surfaced as a VM error; the
    /// answer is always to reattach.
    func attachmentWasDisconnected(error: any Error) {
        Self.logger.warning(
            "Network attachment for '\(self.vmName, privacy: .public)' disconnected: \(error.localizedDescription, privacy: .public)"
        )
        // Ahead of the guards: the framework already nil'd the attachment, and
        // the device's mirror must say so even when this session isn't
        // eligible to reattach right now.
        device.attachmentWasDisconnected()
        guard isActive, isEligible() else { return }
        let isFailedAttachReport =
            lastAttachAttemptAt.map { clock.seconds(since: $0) < disconnectBurstWindow } ?? false
        if isFailedAttachReport {
            // VZ has already nil'd the attachment; reflect that and let the
            // ladder pace the next attempt rather than reattaching in lockstep
            // with a persistently failing attach.
            setPending(device.currentPlan == nil)
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
            Self.logger.warning(
                "Network reconcile for '\(self.vmName, privacy: .public)' found no network choice — leaving the attachment alone"
            )
            setPending(false)
            return
        }

        let desired = resolvePlan(for: choice)
        noteResolvedVmnetKind(desired?.vmnetKind)
        if let desired {
            if device.currentPlan != desired {
                lastAttachAttemptAt = clock.now
                if device.apply(desired) {
                    Self.logger.notice(
                        "Attached network for '\(self.vmName, privacy: .public)' (\(String(describing: desired), privacy: .public), on \(trigger, privacy: .public))"
                    )
                } else {
                    Self.logger.warning(
                        "Could not attach network for '\(self.vmName, privacy: .public)' (\(String(describing: desired), privacy: .public) refused, on \(trigger, privacy: .public))"
                    )
                }
            }
        } else if device.currentPlan != nil {
            // Nothing realizes the choice — a still-usable bridge would have
            // been held by `resolvePlan` — so what remains is stale (its
            // interface vanished) and the honest state is detached.
            device.detach()
        }

        // Never leave an attachment realizing a mode other than the chosen one
        // (a refused apply can leave the previous mode's attachment live): when
        // the chosen mode cannot attach, the honest state is detached, not a
        // substituted mode (docs/NETWORKING.md). A refused apply whose live
        // attachment does match the mode is kept — a working bridge beats
        // detaching, and the next trigger retries.
        if let current = device.currentPlan, !current.matches(choice.mode) {
            device.detach()
        }

        let pending = device.currentPlan == nil
        setPending(pending)
        if pending {
            scheduleRetry()
            if let kind = desired?.vmnetKind { ensureVmnetMaterialization(of: kind) }
        }
    }

    /// Retires what this session claimed about the network it was on when the
    /// chosen mode resolves onto a different one — a live mode switch, or a
    /// bridge going away so the mode resolves to nothing at all. Neither
    /// reaches `setPending(false)`, so without this the claim would outlive
    /// the network it was made about and the report budget would stay spent
    /// against a mode this session has never reported on.
    private func noteResolvedVmnetKind(_ kind: VmnetNetworkKind?) {
        guard kind != resolvedVmnetKind else { return }
        resolvedVmnetKind = kind
        didReportNetworkDefect = false
        reportedDefectiveVmnetKind = nil
    }

    /// Drives the app's vmnet network toward materialized while a session in
    /// a vmnet-backed mode sits detached, reconciling the moment it is ready —
    /// the wake-up signal ladder exhaustion would otherwise leave missing,
    /// since host link changes are a bridged signal and a detached device
    /// fires no disconnects.
    private func ensureVmnetMaterialization(of kind: VmnetNetworkKind) {
        if vmnetMaterializationTask != nil {
            guard vmnetMaterializationKind != kind else { return }
            vmnetMaterializationTask?.cancel()
            vmnetMaterializationTask = nil
        }
        vmnetMaterializationKind = kind
        vmnetMaterializationGeneration += 1
        let generation = vmnetMaterializationGeneration
        vmnetMaterializationTask = Task {
            [weak self, clock, vmnetNetworks, vmnetRematerializeDelays] in
            var attempt = 0
            while !Task.isCancelled {
                guard let coordinator = self, coordinator.isActive, coordinator.isPending else {
                    break
                }
                if await vmnetNetworks.materializeNetwork(for: kind) {
                    self?.clearMaterializationTask(generation: generation)
                    if let coordinator = self, coordinator.isActive {
                        coordinator.reconcile(trigger: "vmnet network materialized")
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
        vmnetMaterializationKind = nil
    }

    /// The plan the chosen mode resolves to right now, `nil` when Bridged has
    /// no usable host interface.
    private func resolvePlan(for choice: NetworkChoice) -> NetworkAttachmentPlan? {
        switch choice.mode {
        case .shared:
            return isVMNetworkingEntitled ? .sharedVmnet : .nat
        case .hostOnly:
            return .hostOnly
        case .bridged:
            let available = interfaces.interfaces().map(\.identifier)
            // The persisted interface is reclaimed the moment the host offers
            // it again; otherwise a live bridge is held while its interface
            // remains available — for Automatic so a default-route change
            // doesn't bounce the guest's link, and for a narrowed fallback so
            // the default route flapping away doesn't detach a working bridge.
            if let persisted = choice.bridgedInterfaceIdentifier, available.contains(persisted) {
                return .bridged(persisted)
            }
            if case .bridged(let current)? = device.currentPlan, available.contains(current) {
                return .bridged(current)
            }
            guard
                let chosen = BridgedInterfaceSelection.choose(
                    persisted: choice.bridgedInterfaceIdentifier,
                    available: available,
                    primary: interfaces.primaryInterfaceIdentifier())
            else { return nil }
            return .bridged(chosen)
        }
    }

    private func scheduleRetry() {
        guard nextRetryIndex < retryDelays.count else {
            ladderExhausted()
            return
        }
        let delay = retryDelays[nextRetryIndex]
        nextRetryIndex += 1
        retryTask = Task { [weak self, clock] in
            do { try await clock.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.reconcile(trigger: "retry", resetBackoff: false)
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    /// A vmnet-backed mode's ladder burning out with the network materialized
    /// is the defective-network signature — VZ accepts each attachment, then
    /// disconnects it — so publish the suspicion, once per pending episode, and
    /// let the library's arbiter decide whether the network can be dropped:
    /// this session sees only itself, and every VM in the mode shares the one
    /// network.
    private func ladderExhausted() {
        guard let choice = choice(), let kind = resolvePlan(for: choice)?.vmnetKind,
            !didReportNetworkDefect
        else { return }
        didReportNetworkDefect = true
        reportedDefectiveVmnetKind = kind
        Self.logger.warning(
            "Network attachment for '\(self.vmName, privacy: .public)' exhausted its ladder on the \(kind.rawValue, privacy: .public) network — reporting it as suspect"
        )
        // Keep driving materialization: the arbiter may refuse the recreate
        // while a sibling holds the network, and a network that simply is not
        // up yet still needs this ladder to bring it back.
        ensureVmnetMaterialization(of: kind)
        // Reported last, so the synchronous arbitration pass it triggers reads
        // this coordinator's settled state.
        onNetworkDefectSuspected()
    }

    /// The arbiter dropped the app-managed network of `kind`; take the recreate
    /// this session's suspicion asked for.
    ///
    /// Both recreate reasons route here — a pending declaration set and a
    /// suspected defect alike — because a session sitting detached on a network
    /// that was just dropped has no other wake-up signal: its retry ladder is
    /// spent and a detached device fires no disconnects.
    /// Ineligible sessions drop it like every other trigger: `reconcile`
    /// refuses to run during a save or a restore, so materializing here would
    /// spin a task whose reconcile is discarded, and the activation at the next
    /// `.running` re-enters anyway.
    func vmnetNetworkWasInvalidated(_ kind: VmnetNetworkKind) {
        guard isActive, isEligible(), isPending,
            choice().flatMap(resolvePlan(for:))?.vmnetKind == kind
        else { return }
        // The recreate answers the claim, so it is withdrawn. `didReportNetworkDefect`
        // deliberately stays set: a recreate that comes up just as defective
        // must not report again and start a recreate loop.
        reportedDefectiveVmnetKind = nil
        // Cancel first: the in-flight task's own ladder may already be spent,
        // and the single-flight guard would otherwise swallow this nudge.
        vmnetMaterializationTask?.cancel()
        vmnetMaterializationTask = nil
        vmnetMaterializationKind = nil
        // No direct reconcile: the materialization task reconciles on success,
        // which keeps this out of the arbitration pass the report unwound from.
        ensureVmnetMaterialization(of: kind)
    }

    private func setPending(_ pending: Bool) {
        guard pending != isPending else { return }
        isPending = pending
        if !pending {
            didReportNetworkDefect = false
            // An attached session suspects nothing — the claim is withdrawn
            // even if the arbiter never got to act on it.
            reportedDefectiveVmnetKind = nil
        }
        Self.logger.notice(
            "Network attachment for '\(self.vmName, privacy: .public)' is \(pending ? "pending reattach" : "attached", privacy: .public)"
        )
        onPendingChange(pending)
    }

    #if DEBUG
    /// The in-flight backoff retry, for event-driven test waits.
    var retryTaskForTesting: Task<Void, Never>? { retryTask }
    /// The in-flight vmnet materialization, for event-driven test waits.
    var vmnetMaterializationTaskForTesting: Task<Void, Never>? { vmnetMaterializationTask }
    #endif
}
