import Foundation
import Observation

@testable import KernovaCore

/// A source whose every check and Use Defaults waits until the test ends
/// it.
@MainActor
@Observable
final class GatedConfigCheckSource: ConfigCheckSource {
    private(set) var checks: [CheckedContinuation<[UnreadableConfigFile], any Error>] = []
    private(set) var repairs: [CheckedContinuation<[VMLibrary.ConfigFileRepairFailure], Never>] = []

    func checkConfigFiles() async throws -> [UnreadableConfigFile] {
        try await withCheckedThrowingContinuation { checks.append($0) }
    }

    func useDefaults(in files: [UnreadableConfigFile]) async -> [VMLibrary.ConfigFileRepairFailure] {
        await withCheckedContinuation { repairs.append($0) }
    }

    var libraryDirectory: URL? { nil }
}
