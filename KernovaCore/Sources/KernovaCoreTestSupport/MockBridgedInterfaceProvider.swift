import Synchronization

@testable import KernovaCore

/// Scripted stand-in for `BridgedInterfaceProviding`, so tests resolve a bridged
/// interface off a fixed list rather than the host's live one.
///
/// Both answers stay settable so a test can change what the host offers between
/// menu rebuilds.
final class MockBridgedInterfaceProvider: BridgedInterfaceProviding {
    private struct State {
        var available: [BridgedInterface]
        var primary: String?
    }

    private let state: Mutex<State>

    init(available: [BridgedInterface] = [], primary: String? = nil) {
        state = Mutex(State(available: available, primary: primary))
    }

    /// Sets the interfaces every later enumeration returns.
    func setAvailable(_ available: [BridgedInterface]) {
        state.withLock { $0.available = available }
    }

    /// Sets the identifier every later primary-interface read returns.
    func setPrimary(_ primary: String?) {
        state.withLock { $0.primary = primary }
    }

    func interfaces() -> [BridgedInterface] { state.withLock { $0.available } }
    func primaryInterfaceIdentifier() -> String? { state.withLock { $0.primary } }
}
