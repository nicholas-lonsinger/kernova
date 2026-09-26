import Foundation
import KernovaTestSupport
@testable import Kernova

extension VMLibrary {
    /// Begins a real arrival for `configuration` whose write waits on `gate`
    /// and then writes the configuration into its staged bundle, so a release
    /// publishes and adopts a readable bundle.
    @discardableResult
    func beginGatedArrival(
        _ kind: VMArrival.Kind = .importing, configuration: VMConfiguration,
        gate: GatedStep
    ) -> VMArrival {
        let storage = storageService
        let destination: URL
        let staged: VMStagedBundle
        do {
            destination = try storage.bundleURL(for: configuration)
            staged = try VMStagedBundle.mint(in: storage)
        } catch {
            preconditionFailure("A test arrival's destination could not be derived: \(error)")
        }
        return beginArrival(
            kind: kind, configuration: configuration, destination: destination, staged: staged
        ) { staged in
            try await gate.pass()
            try storage.createVMBundle(at: staged.url)
            try staged.writeInitial(configuration)
        }
    }

    /// ``beginGatedArrival(_:configuration:gate:)`` for a fresh configuration
    /// named `name`.
    @discardableResult
    func beginGatedArrival(
        _ kind: VMArrival.Kind = .importing, named name: String, guestOS: VMGuestOS = .linux,
        gate: GatedStep
    ) -> VMArrival {
        var configuration = VMConfiguration(
            name: name, guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi)
        configuration.networkEnabled = false
        return beginGatedArrival(kind, configuration: configuration, gate: gate)
    }
}

extension VMArrival {
    /// An arrival of `kind` for `configuration` whose write fails at once,
    /// for a surface that only reads its row.
    static func inert(_ kind: Kind, configuration: VMConfiguration) -> VMArrival {
        VMArrival(
            id: configuration.id, kind: kind, configuration: configuration,
            destinationURL: VMInstanceFixture.bundleURL(for: configuration.id),
            staged: VMStagedBundle.fixtureForTesting(
                at: VMInstanceFixture.bundleURL(for: UUID()), access: InMemoryVMBundleFiles())
        ) { _ in throw CancellationError() }
    }

    /// Waits for the arrival to settle — its row already replaced by the VM
    /// or removed — answering the VM it became, or `nil` when it became none.
    @discardableResult
    func settle() async -> VMInstance? {
        try? await settled.value
    }
}
