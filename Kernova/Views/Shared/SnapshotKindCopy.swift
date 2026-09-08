/// The one rendering of what a snapshot captured — Get Info's "Captured" row,
/// the snapshot row's subtitle, and the Ephemeral baseline menu all read it.
enum SnapshotKindCopy {
    /// What reverting to a snapshot of `kind` puts back.
    static func captured(_ kind: VMSnapshotKind) -> String {
        switch kind {
        case .warm: "Memory and disks"
        case .cold: "Disks only"
        }
    }
}
