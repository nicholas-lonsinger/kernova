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
    /// Awaits the app's first library read.
    private let awaitReady: @Sendable () async -> Void

    /// The single await, memoized.
    private var readiness: Task<Void, Never>?

    init(awaitReady: @escaping @Sendable () async -> Void) {
        self.awaitReady = awaitReady
    }

    /// Returns once the app's first library read has landed.
    func ready() async {
        if let readiness {
            await readiness.value
            return
        }
        let task = Task { [awaitReady] in await awaitReady() }
        readiness = task
        await task.value
    }
}
