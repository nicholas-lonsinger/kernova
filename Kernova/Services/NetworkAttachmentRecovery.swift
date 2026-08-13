import Foundation
import SystemConfiguration
import Virtualization
import os

/// A realizable network attachment for a live VM, decoupled from VZ for testability.
enum NetworkAttachmentPlan: Equatable {
    case nat
    case bridged(String)

    /// Whether this plan realizes `mode` — a NAT attachment realizes Shared
    /// Network, a bridged attachment over any interface realizes Bridged.
    func matches(_ mode: VMNetworkMode) -> Bool {
        switch (self, mode) {
        case (.nat, .shared), (.bridged, .bridged): true
        case (.nat, .bridged), (.bridged, .shared): false
        }
    }
}

/// The network the user chose for a VM, as attachment recovery needs it.
struct NetworkChoice: Equatable {
    let mode: VMNetworkMode
    /// The persisted bridged interface, `nil` for Automatic.
    let bridgedInterfaceIdentifier: String?
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
}

/// Drives a `VZNetworkDevice`, re-fetching the concrete
/// `VZBridgedNetworkInterface` by identifier at each attach — a VZ interface
/// object held across a link change is stale.
@MainActor
final class VZNetworkDeviceHandle: NetworkDeviceControlling {
    private let device: VZNetworkDevice

    init(device: VZNetworkDevice) {
        self.device = device
    }

    var currentPlan: NetworkAttachmentPlan? {
        switch device.attachment {
        case is VZNATNetworkDeviceAttachment:
            .nat
        case let bridged as VZBridgedNetworkDeviceAttachment:
            .bridged(bridged.interface.identifier)
        default:
            nil
        }
    }

    func apply(_ plan: NetworkAttachmentPlan) -> Bool {
        switch plan {
        case .nat:
            device.attachment = VZNATNetworkDeviceAttachment()
            return true
        case .bridged(let identifier):
            guard
                let interface = VZBridgedNetworkInterface.networkInterfaces.first(where: {
                    $0.identifier == identifier
                })
            else { return false }
            device.attachment = VZBridgedNetworkDeviceAttachment(interface: interface)
            return true
        }
    }

    func detach() {
        device.attachment = nil
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
    private var onChange: (() -> Void)?

    func start(onChange: @escaping @MainActor () -> Void) {
        stop()
        self.onChange = onChange

        // The store retains `self` through the context until `stop()` releases
        // the store, so a callback queued behind teardown never sees a dangling
        // pointer.
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                _ = Unmanaged<AnyObject>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                Unmanaged<AnyObject>.fromOpaque(info).release()
            },
            copyDescription: nil)
        guard
            let store = SCDynamicStoreCreate(
                nil, "Kernova.NetworkLinkObserver" as CFString,
                { _, _, info in
                    guard let info else { return }
                    let observer = Unmanaged<HostNetworkLinkObserver>.fromOpaque(info)
                        .takeUnretainedValue()
                    Task { @MainActor in observer.onChange?() }
                },
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

/// Keeps one VM session's live network attachment realizing the mode the user
/// chose — across VZ's attachment-disconnect callback, a boot or restore that
/// came up detached, host link changes, and live mode/interface edits.
///
/// Recovery narrows but never escalates: a bridged VM whose interface is gone
/// falls back within Bridged (to the default-route interface) or runs detached
/// until one returns — it never silently becomes Shared Network, and no mode
/// is ever attached that the user didn't choose (docs/NETWORKING.md).
///
/// Created by `VMInstance` alongside the `VZVirtualMachine`; `activate()` is
/// deferred until the session reaches `.running`, since VZ documents runtime
/// attachment swapping for a running VM only.
@MainActor
final class NetworkAttachmentCoordinator {
    private static let logger = Logger(
        subsystem: "app.kernova", category: "NetworkAttachmentCoordinator")

    /// Reattempt cadence after a failed attach, reset by each fresh trigger.
    /// Bounded: once exhausted, the next link change or disconnect tries again.
    /// It exists because `VZBridgedNetworkInterface.networkInterfaces` can lag
    /// the dynamic-store event announcing the interface.
    static let defaultRetryDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(4), .seconds(8),
    ]

    /// Two disconnects inside this window mean VZ is failing reattach attempts
    /// as fast as they are made — setting `VZNetworkDevice.attachment` reports
    /// failure only asynchronously, through another disconnect callback — so
    /// the burst routes through the bounded retry ladder instead of
    /// reattaching immediately, which would spin at VZ's failure cadence.
    static let defaultDisconnectBurstWindow: Duration = .seconds(1)

    private let vmName: String
    private let device: any NetworkDeviceControlling
    private let interfaces: any BridgedInterfaceProviding
    private let linkObserver: any NetworkLinkObserving
    private let retryDelays: [Duration]
    private let disconnectBurstWindow: Duration
    private let clock = ContinuousClock()
    private var lastDisconnectAt: ContinuousClock.Instant?
    private let choice: @MainActor () -> NetworkChoice?
    private let onPendingChange: @MainActor (Bool) -> Void

    /// `true` while the device is detached — no attachment realizes the chosen
    /// mode and recovery is waiting to reattach.
    private(set) var isPending = false
    private var isActive = false
    private var retryTask: Task<Void, Never>?
    private var nextRetryIndex = 0

    init(
        vmName: String,
        device: any NetworkDeviceControlling,
        interfaces: any BridgedInterfaceProviding,
        linkObserver: any NetworkLinkObserving,
        retryDelays: [Duration] = NetworkAttachmentCoordinator.defaultRetryDelays,
        disconnectBurstWindow: Duration = NetworkAttachmentCoordinator.defaultDisconnectBurstWindow,
        choice: @escaping @MainActor () -> NetworkChoice?,
        onPendingChange: @escaping @MainActor (Bool) -> Void
    ) {
        self.vmName = vmName
        self.device = device
        self.interfaces = interfaces
        self.linkObserver = linkObserver
        self.retryDelays = retryDelays
        self.disconnectBurstWindow = disconnectBurstWindow
        self.choice = choice
        self.onPendingChange = onPendingChange
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
    }

    /// VZ's attachment-disconnect callback: the framework has nil'd the
    /// attachment. Benign by design — it also fires on initial boot, device
    /// reset, and guest reboot — so it is never surfaced as a VM error; the
    /// answer is always to reattach.
    func attachmentWasDisconnected(error: any Error) {
        Self.logger.warning(
            "Network attachment for '\(self.vmName, privacy: .public)' disconnected: \(error.localizedDescription, privacy: .public)"
        )
        guard isActive else { return }
        let now = clock.now
        let isBurst = lastDisconnectAt.map { now - $0 < disconnectBurstWindow } ?? false
        lastDisconnectAt = now
        if isBurst {
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
        if let desired, device.currentPlan != desired {
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

        // Never leave an attachment realizing a mode other than the chosen one:
        // when the chosen mode cannot attach, the honest state is detached, not
        // a substituted mode (docs/NETWORKING.md).
        if let current = device.currentPlan, !current.matches(choice.mode) {
            device.detach()
        }

        let pending = device.currentPlan == nil
        setPending(pending)
        if pending { scheduleRetry() }
    }

    /// The plan the chosen mode resolves to right now, `nil` when Bridged has
    /// no usable host interface.
    private func resolvePlan(for choice: NetworkChoice) -> NetworkAttachmentPlan? {
        switch choice.mode {
        case .shared:
            return .nat
        case .bridged:
            let available = interfaces.interfaces().map(\.identifier)
            // A live Automatic bridge holds its interface while the host still
            // offers it: Automatic resolves at boot and reattach, not
            // continuously — chasing every default-route change would bounce
            // the guest's link for nothing.
            if choice.bridgedInterfaceIdentifier == nil,
                case .bridged(let current)? = device.currentPlan,
                available.contains(current)
            {
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
        guard nextRetryIndex < retryDelays.count else { return }
        let delay = retryDelays[nextRetryIndex]
        nextRetryIndex += 1
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.reconcile(trigger: "retry", resetBackoff: false)
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    private func setPending(_ pending: Bool) {
        guard pending != isPending else { return }
        isPending = pending
        Self.logger.notice(
            "Network attachment for '\(self.vmName, privacy: .public)' is \(pending ? "pending reattach" : "attached", privacy: .public)"
        )
        onPendingChange(pending)
    }

    #if DEBUG
    /// The in-flight backoff retry, for event-driven test waits.
    var retryTaskForTesting: Task<Void, Never>? { retryTask }
    #endif
}
