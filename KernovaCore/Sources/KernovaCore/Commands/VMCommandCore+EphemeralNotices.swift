import Foundation

/// The note a settings verb answers with when the settings it changed go back
/// to a VM's Ephemeral baseline at the next shutdown.
extension VMCommandCore {
    /// Runs `body`, answering what it returned and a notice for each VM whose
    /// settings it moved in a way the next shutdown's revert undoes.
    ///
    /// Judged per VM on the move from what it held before `body` to what it
    /// holds after (``VMConfiguration/movesFieldARevertRestores(to:)``), so a
    /// verb that moves several VMs' settings names each one it moved.
    func noticingEphemeralReverts<T>(
        _ body: () async throws -> T
    ) async throws -> (value: T, notices: [String]) {
        let before = Dictionary(
            library.instances.map { ($0.id, $0.configuration) }, uniquingKeysWith: { first, _ in first })
        let value = try await body()
        return (value, ephemeralRevertNotices(since: before))
    }

    /// A notice for each VM with an Ephemeral baseline whose configuration
    /// moved since `before` in a way a revert undoes, unless the user turned
    /// the notice off.
    func ephemeralRevertNotices(since before: [UUID: VMConfiguration]) -> [String] {
        guard !preferences.ephemeralSettingsBannerDismissed else { return [] }
        return library.instances.compactMap { instance in
            guard let baseline = instance.ephemeralBaselineSnapshot,
                let held = before[instance.id],
                held.movesFieldARevertRestores(to: instance.configuration)
            else { return nil }
            return EphemeralModeCopy.settingsRevertNotice(vm: instance.name, baseline: baseline.name)
        }
    }
}
