import Foundation

/// The app's first library read, awaited once however many front doors ask.
///
/// Every automation front door faces the same race: a request can be delivered
/// while the launch's library read is still in flight, and a verb run against a
/// library that has not landed yet refuses with "no virtual machine named…".
/// One instance is shared by every door, so a burst of requests — however many
/// doors they arrive through — parks on a single task.
@MainActor
final class LibraryReadiness {
    /// The single await, started with the instance so the landing is on record
    /// whether or not a door has asked yet.
    private let landing: Task<Void, Never>

    /// Whether the read has landed — what a door that cannot suspend reads.
    private(set) var hasLanded = false

    init(awaitReady: @escaping @Sendable () async -> Void) {
        landing = Task { await awaitReady() }
        Task { [weak self] in await self?.ready() }
    }

    /// Returns once the app's first library read has landed.
    func ready() async {
        await landing.value
        hasLanded = true
    }
}
