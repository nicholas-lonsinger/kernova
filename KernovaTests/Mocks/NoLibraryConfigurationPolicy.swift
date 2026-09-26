import Foundation
@testable import Kernova

/// The configuration policy of a fixture bundle no library has admitted:
/// nothing across VMs to refuse, and no live policy to carry a commit to.
/// ``VMLibrary/admitForTesting(_:)`` replaces it with the library's own.
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
