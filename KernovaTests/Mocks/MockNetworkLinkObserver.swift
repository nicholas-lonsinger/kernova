@testable import Kernova

/// Scripted stand-in for `NetworkLinkObserving`; tests fire link-change events
/// with `fire()`.
@MainActor
final class MockNetworkLinkObserver: NetworkLinkObserving {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var onChange: (() -> Void)?

    var isObserving: Bool { onChange != nil }

    func start(onChange: @escaping @MainActor () -> Void) {
        startCount += 1
        self.onChange = onChange
    }

    func stop() {
        stopCount += 1
        onChange = nil
    }

    func fire() {
        onChange?()
    }
}
