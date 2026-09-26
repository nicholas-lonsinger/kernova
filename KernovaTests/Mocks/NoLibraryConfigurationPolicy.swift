import Foundation
@testable import Kernova

/// The configuration policy of a fixture VM no library holds: nothing across
/// VMs to refuse, and no live policy to carry a commit to. A library admits
/// only a bundle its own factory builds
/// (``VMLibrary/admitForTesting(_:phase:preferences:)``), so a bundle over
/// this policy never joins one.
@MainActor
final class NoLibraryConfigurationPolicy: VMConfigurationPolicy {
    func refusal(
        on instance: VMInstance, movingFrom old: VMConfiguration, to new: VMConfiguration,
        under authority: VMEditPermit.Authority
    ) -> (any Error)? {
        nil
    }

    func committed(on instance: VMInstance, from old: VMConfiguration, to new: VMConfiguration) {}
}

extension VMBundle.Factory {
    /// A factory for fixture bundles, over ``NoLibraryConfigurationPolicy``.
    @MainActor
    init(machineFiles: any VMBundleMachineFileWorking) {
        self.init(machineFiles: machineFiles, configurationPolicy: NoLibraryConfigurationPolicy())
    }
}
