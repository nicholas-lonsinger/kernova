import Foundation

/// The access each caught drag's drop conveyed to its files, held by generation
/// until the host is done pulling them.
///
/// A drop destination receives access to the dropped files only through the
/// URL objects it reads off the dragging pasteboard during the drop, and the
/// host pulls the items after the drop has concluded, so a file in a
/// privacy-protected folder (`~/Desktop`, `~/Documents`, `~/Downloads`) is
/// readable without a prompt only while that access is held.
@MainActor
final class GuestDropGrants {
    private let scope: any GuestDropAccessScope
    /// The URLs whose access started, by the generation they were dropped for.
    private var held: [UInt64: [URL]] = [:]

    init(scope: any GuestDropAccessScope) {
        self.scope = scope
    }

    /// Starts access to each of `urls` — the exact objects the drop read — and
    /// holds the ones that started against `generation`.
    func hold(_ urls: [URL], for generation: UInt64) {
        held[generation, default: []] += urls.filter { scope.start($0) }
    }

    /// Stops the access held for `generation`, which nothing will pull again.
    func release(generation: UInt64) {
        guard let urls = held.removeValue(forKey: generation) else { return }
        urls.forEach(scope.stop)
    }

    /// Stops every access held; the connection the drags went out on is over.
    func releaseAll() {
        let all = held
        held.removeAll()
        for urls in all.values { urls.forEach(scope.stop) }
    }
}

/// Starts and stops access to one dropped file.
@MainActor
protocol GuestDropAccessScope: AnyObject {
    /// Starts access to `url`, returning whether it started — so whether
    /// ``stop(_:)`` is owed.
    func start(_ url: URL) -> Bool

    /// Stops access ``start(_:)`` started.
    func stop(_ url: URL)
}

/// The URL's own security scope, which a drop's URL carries.
@MainActor
final class SecurityScopedDropAccess: GuestDropAccessScope {
    func start(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stop(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}
