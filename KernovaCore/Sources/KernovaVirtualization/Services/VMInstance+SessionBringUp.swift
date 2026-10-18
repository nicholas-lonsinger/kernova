import Foundation
import KernovaCore
import Virtualization

/// The engine's half of a bring-up: creating the `VZVirtualMachine` a built
/// configuration describes and handing its session to the VM to hold.
extension VMInstance {
    /// Brings a built configuration all the way up: adopts its pipes and media,
    /// creates the `VZVirtualMachine`, and starts the serial, clipboard and
    /// vsock plumbing that rides it.
    ///
    /// The whole of what a boot path does between building a configuration and
    /// telling VZ to run, so a cold boot and a restore cannot drift apart. The
    /// install path stops short of the vsock listeners and stays hand-wired.
    ///
    /// `nil` for the same reason ``attachSession(_:from:)`` returns `nil`, and
    /// the caller must not proceed to start anything.
    func bringUpSession(
        _ context: borrowing VMBringUpContext, with result: sending ConfigurationBuilder.BuildResult
    ) async -> VMSession? {
        adoptBuildProducts(context, result.products)
        guard let session = await attachSession(context, from: result) else { return nil }
        startSerialReading()
        startClipboardService()
        await startVsockServices()
        return session
    }

    /// Creates the VM `result` describes on its own queue, binds its session to
    /// the bring-up holding this VM (``VMActivity/beginSession(_:_:)``), and
    /// builds the network-attachment coordinator for network-enabled
    /// configurations.
    ///
    /// `nil` exactly when ``VMActivity/beginSession(_:_:)`` is; the
    /// just-created `VZVirtualMachine` is then released with its session.
    func attachSession(
        _ context: borrowing VMBringUpContext, from result: sending ConfigurationBuilder.BuildResult
    ) async -> VMSession? {
        // Read before the send: region analysis treats `result` as one value,
        // so no field of it is readable once `configuration` is sent.
        let networks = result.products.vmnetNetworks
        let recovery = result.attachmentRecovery
        let session = await VMSession.make(configuration: result.configuration, events: makeSessionEvents())
        guard let sessionContext = beginSession(context, session) else { return nil }
        await setupNetworkAttachmentCoordinator(
            for: session, in: sessionContext, networks: networks, recovery: recovery)
        return session
    }

    /// Builds this session's attachment-recovery coordinator, replacing any
    /// prior one.
    private func setupNetworkAttachmentCoordinator(
        for session: VMSession, in context: VMSessionContext,
        networks: VmnetSessionNetworks, recovery: ConfigurationBuilder.AttachmentRecoverySources
    ) async {
        context.networkAttachmentCoordinator?.stop()
        context.networkAttachmentCoordinator = nil
        context.networkAttachmentPending = false
        guard configuration.networkEnabled, session.hasNetworkDevice else { return }
        let initialPlan = await session.inspectNetworkAttachment { attachment in
            VZNetworkDeviceHandle.plan(of: attachment, in: networks)
        }
        guard self.session === session else { return }
        context.networkAttachmentCoordinator = NetworkAttachmentCoordinator(
            vmName: name,
            device: VZNetworkDeviceHandle(
                session: session, initialPlan: initialPlan, vmnetNetworks: networks,
                vmnetAttachments: recovery.vmnetAttachments),
            interfaces: recovery.bridgedInterfaces,
            linkObserver: HostNetworkLinkObserver(),
            vmnetNetworks: networks,
            entitlements: recovery.entitlements,
            isEligible: { [weak self] in self?.hasLiveSession ?? false },
            choice: { [weak self] in self?.configuration.networkChoice },
            onPendingChange: { [weak context] pending in
                context?.networkAttachmentPending = pending
            })
    }
}
