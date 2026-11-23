@testable import KernovaCore

/// No-op stand-in for `NetworkLinkObserving`: no link change ever fires.
@MainActor
final class MockNetworkLinkObserver: NetworkLinkObserving {
    func start(onChange: @escaping @MainActor () -> Void) {}

    func stop() {}
}
