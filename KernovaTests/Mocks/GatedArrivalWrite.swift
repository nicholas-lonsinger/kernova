import Foundation
import KernovaTestSupport
@testable import Kernova

/// The bundle write of an arrival a test holds in flight: it parks until
/// ``release(throwing:)``, the way an uninterruptible copy runs to its end
/// whether or not the arrival was cancelled meanwhile.
@MainActor
final class GatedArrivalWrite {
    /// Fires as the write begins parking.
    let entered = AsyncGate()
    private(set) var hasEntered = false
    private var outcome: Result<Void, any Error>?
    private var parked: [CheckedContinuation<Void, any Error>] = []

    /// Lets the write finish — writing its bundle, or throwing `error`.
    func release(throwing error: (any Error)? = nil) {
        let result: Result<Void, any Error> = error.map { .failure($0) } ?? .success(())
        outcome = result
        let waiting = parked
        parked.removeAll()
        for continuation in waiting { continuation.resume(with: result) }
    }

    /// Parks until released, answering what the release carried.
    func pass() async throws {
        hasEntered = true
        entered.notify()
        if let outcome { return try outcome.get() }
        try await withCheckedThrowingContinuation { parked.append($0) }
    }
}

extension VMLibrary {
    /// Begins a real arrival for `configuration` whose write waits on `gate`
    /// and then writes the configuration into its staged bundle, so a release
    /// publishes and adopts a readable bundle.
    @discardableResult
    func beginGatedArrival(
        _ kind: VMArrival.Kind = .importing, configuration: VMConfiguration,
        gate: GatedArrivalWrite
    ) -> VMArrival {
        let storage = storageService
        let destination: URL
        do {
            destination = try storage.bundleURL(for: configuration)
        } catch {
            preconditionFailure("A test arrival's destination could not be derived: \(error)")
        }
        return beginArrival(kind: kind, configuration: configuration, destination: destination) {
            staged in
            try await gate.pass()
            try storage.createVMBundle(at: staged)
            try VMBundleFiles(url: staged, access: storage.bundleFiles).writeInitial(configuration)
        }
    }

    /// ``beginGatedArrival(_:configuration:gate:)`` for a fresh configuration
    /// named `name`.
    @discardableResult
    func beginGatedArrival(
        _ kind: VMArrival.Kind = .importing, named name: String, guestOS: VMGuestOS = .linux,
        gate: GatedArrivalWrite
    ) -> VMArrival {
        var configuration = VMConfiguration(
            name: name, guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi)
        configuration.networkEnabled = false
        return beginGatedArrival(kind, configuration: configuration, gate: gate)
    }
}

extension VMArrival {
    /// Waits for the arrival to settle — its row already replaced by the VM
    /// or removed — answering the VM it became, or `nil` when it became none.
    @discardableResult
    func settle() async -> VMInstance? {
        try? await settled.value
    }
}
