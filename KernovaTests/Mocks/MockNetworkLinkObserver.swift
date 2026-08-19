@testable import Kernova

/// Scripted stand-in for `NetworkLinkObserving`; tests fire link-change events
/// with `fire()`.
@MainActor
final class MockNetworkLinkObserver: NetworkLinkObserving {
    private var onChange: (() -> Void)?

    var isObserving: Bool { onChange != nil }

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func stop() {
        onChange = nil
    }

    func fire() {
        onChange?()
    }
}
