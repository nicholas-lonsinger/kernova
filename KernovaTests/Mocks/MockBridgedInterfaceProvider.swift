@testable import Kernova

/// Scripted stand-in for `BridgedInterfaceProviding`, so tests resolve a bridged
/// interface off a fixed list rather than the host's live one.
///
/// Both values stay mutable so a test can change what the host offers between
/// menu rebuilds; `@unchecked Sendable` covers the nonisolated protocol, and
/// every test touching one runs on the main thread.
final class MockBridgedInterfaceProvider: BridgedInterfaceProviding, @unchecked Sendable {
    var available: [BridgedInterface]
    var primary: String?

    init(available: [BridgedInterface] = [], primary: String? = nil) {
        self.available = available
        self.primary = primary
    }

    func interfaces() -> [BridgedInterface] { available }
    func primaryInterfaceIdentifier() -> String? { primary }
}
