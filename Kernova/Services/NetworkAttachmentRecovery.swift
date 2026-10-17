import Foundation
import KernovaCore
import KernovaLogging
import SystemConfiguration
import Virtualization

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
    private let vmnetNetworks: VmnetSessionNetworks
    private let vmnetAttachments: any VmnetAttachmentMaking

    /// The plan the device is on: what `apply`/`detach` last installed,
    /// cleared when the framework reports the attachment disconnected.
    private var appliedPlan: NetworkAttachmentPlan?

    /// Counts the applies made, so a build failure reported after a later
    /// apply has landed cannot pull the mirror backwards.
    private var appliedGeneration = 0

    init(
        session: any NetworkAttachmentInstalling,
        initialPlan: NetworkAttachmentPlan?,
        vmnetNetworks: VmnetSessionNetworks,
        vmnetAttachments: any VmnetAttachmentMaking
    ) {
        self.session = session
        self.appliedPlan = initialPlan
        self.vmnetNetworks = vmnetNetworks
        self.vmnetAttachments = vmnetAttachments
    }

    /// Classifies a live attachment back to the plan it realizes — run on the
    /// session's queue to seed `initialPlan` from the attachment the
    /// configuration build installed. A network the service does not hold
    /// realizes nothing, so reconciliation replaces it.
    nonisolated static func plan(
        of attachment: VZNetworkDeviceAttachment, in vmnetNetworks: VmnetSessionNetworks
    ) -> NetworkAttachmentPlan? {
        switch attachment {
        case is VZNATNetworkDeviceAttachment:
            .nat
        case let bridged as VZBridgedNetworkDeviceAttachment:
            .bridged(bridged.interface.identifier)
        case let vmnet as VZVmnetNetworkDeviceAttachment:
            vmnetNetworks.selection(ofNetwork: vmnet.network).map(NetworkAttachmentPlan.vmnet)
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
        case .vmnet(let selection):
            // Non-blocking: an unmaterialized network refuses the apply, and
            // the coordinator materializes it off-main and reconciles when
            // it's ready.
            guard vmnetNetworks.joinedNetworkIfMaterialized(for: selection) != nil else { return false }
            make = { [vmnetNetworks, vmnetAttachments] in
                vmnetNetworks.joinedNetworkIfMaterialized(for: selection)
                    .map(vmnetAttachments.attachment(joining:))
            }
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

/// Observes host link changes through the SystemConfiguration dynamic store:
/// the IPv4/IPv6 global (default-route) state plus every interface's link key.
@MainActor
final class HostNetworkLinkObserver: NetworkLinkObserving {
    private static let logger = KernovaLogger(
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
            #log(Self.logger, .fault, "SCDynamicStoreCreate returned nil — link changes go unobserved")
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

// `SCDynamicStore` invokes these on the store's dispatch queue. A closure
// literal formed inside the `@MainActor` class gets main-actor isolation plus a
// dynamic check, which traps (`EXC_BREAKPOINT` in `dispatch_assert_queue`) when
// a real link event fires — observed on a host-only VM's first boot, which
// reconfigures host interfaces and fires the event immediately.

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
