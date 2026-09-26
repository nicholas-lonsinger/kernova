import Foundation

@testable import Kernova

/// A plain instance list in place of ``VMLibrary``, so a collaborator that only
/// reads the roster can be driven without one.
///
/// Like the library, it is its instances' ``VMAdmissionPeers``: no clone in
/// flight, no identity conflict, and USB passthrough or a termination only
/// once a test says so.
@MainActor
final class StubVMInstanceRoster: VMInstanceRoster, VMAdmissionPeers {
    var instances: [VMInstance] {
        didSet { wirePeers() }
    }

    var supportsUSBAccessories = false

    var isTerminating = false

    init(_ instances: [VMInstance] = []) {
        self.instances = instances
        wirePeers()
    }

    func hasCloneInFlight(from instance: VMInstance) -> Bool { false }

    func identityConflict(
        for instance: VMInstance, bringingUp configuration: VMConfiguration
    ) -> VMIdentityConflict? { nil }

    private func wirePeers() {
        for instance in instances { instance.peers = self }
    }
}
