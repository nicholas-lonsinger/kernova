import Foundation

@testable import Kernova

/// A ``VMIndexRecording`` double holding the record in memory.
///
/// `Sendable` by main-actor isolation, which is also where the gateway reads
/// and writes it from — so a test reads `indexedVMIDs` without a hop.
@MainActor
final class MockVMIndexRecord: VMIndexRecording {
    var indexedVMIDs: Set<UUID>

    /// Starts holding `indexed`, which stands in for an earlier run's record.
    init(_ indexed: Set<UUID> = []) {
        indexedVMIDs = indexed
    }
}
