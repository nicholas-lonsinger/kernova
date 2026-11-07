import Foundation
import KernovaCommandModel

/// The configuration moves committed in one request's task, and any child
/// task it spawns, by VM.
///
/// ``VMLibrary`` records each commit into ``current`` as it lands. A commit
/// from another task — a concurrent edit, another request, a guest's report
/// landing while it awaited — is never recorded; one a spawned task makes
/// after the response is built is recorded but never read.
@MainActor
final class VMConfigurationCommitRecord {
    /// The record of the request the current task is answering, `nil` outside
    /// one that asked for its commits to be recorded.
    @TaskLocal nonisolated static var current: VMConfigurationCommitRecord?

    /// What one VM's configuration held before the request's first commit to
    /// it, and after its last.
    struct Move {
        let from: VMConfiguration
        let to: VMConfiguration
    }

    private(set) var moves: [UUID: Move] = [:]

    /// Records a commit that moved `instance`'s configuration from `from` to
    /// `to`.
    func record(_ instance: UUID, from: VMConfiguration, to: VMConfiguration) {
        moves[instance] = Move(from: moves[instance]?.from ?? from, to: to)
    }
}

extension VMCommandCore {
    /// A notice for each VM `record` moved in a way the next shutdown's revert
    /// to its Ephemeral baseline undoes
    /// (``VMConfiguration/movesFieldARevertRestores(to:)``), unless the user
    /// turned the notice off.
    func ephemeralRevertNotices(_ record: VMConfigurationCommitRecord) -> [VMCommandNotice] {
        guard !preferences.ephemeralSettingsBannerDismissed else { return [] }
        return library.instances.compactMap { instance in
            guard let move = record.moves[instance.id],
                move.from.movesFieldARevertRestores(to: move.to),
                let baseline = instance.ephemeralBaselineSnapshot
            else { return nil }
            return .ephemeralRevert(
                vm: summary(instance), baseline: snapshotSummary(baseline, on: instance))
        }
    }
}
