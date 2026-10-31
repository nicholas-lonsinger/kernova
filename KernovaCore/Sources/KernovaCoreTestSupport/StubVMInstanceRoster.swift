import Foundation

@testable import KernovaCore

/// A plain instance list in place of ``VMLibrary``, so a collaborator that only
/// reads the roster can be driven without one.
///
/// Like the library, it is its instances' ``VMAdmissionPeers``: no identity
/// conflict, and USB passthrough or a termination only once a test says so.
@MainActor
final class StubVMInstanceRoster: VMAdmissionPeers {
    var instances: [VMInstance] {
        didSet { wirePeers() }
    }

    var usbPassthroughGap: USBAccessoryPassthrough.Gap? = .needsEntitlement

    var isTerminating = false

    let accessoryHolders = VMAccessoryHolders()

    init(_ instances: [VMInstance] = []) {
        self.instances = instances
        wirePeers()
    }

    func identityConflict(
        for instance: VMInstance, bringingUp configuration: VMConfiguration,
        override: VMIdentityOverride
    ) -> VMIdentityConflict? { nil }

    /// Nothing: with no library there is no reconciler to run one.
    func oweRemovableMediaReconcile(to instance: VMInstance, for sessionID: UUID) {}

    private func wirePeers() {
        for instance in instances { instance.peers = self }
    }
}
