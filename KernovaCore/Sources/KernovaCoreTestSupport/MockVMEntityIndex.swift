import Foundation

@testable import KernovaCore

/// A ``VMEntityIndexing`` double that keeps every write off Spotlight.
@MainActor
final class MockVMEntityIndex: VMEntityIndexing {
    func index(_ vms: [VMEntity]) async throws {}

    func remove(_ ids: [UUID]) async throws {}
}
