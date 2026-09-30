/// The one rendering of a snapshot's kind — the snapshot row's subtitle, a
/// Shortcuts snapshot's subtitle, and Get Info's "Captured" row all read it.
enum SnapshotKindCopy {
    /// The state a revert to a snapshot of `kind` leaves the VM in, short
    /// enough to sit between a row's date and its size.
    static func stateLabel(_ kind: VMSnapshotKind) -> String {
        switch kind {
        case .warm: "Running state"
        case .cold: "Powered off"
        }
    }

    /// What reverting to a snapshot of `kind` puts back, for Get Info. Both
    /// kinds carry the VM's settings, so the running state is the part that
    /// tells them apart.
    static func capturedContents(_ kind: VMSnapshotKind) -> String {
        switch kind {
        case .warm: "Running state, disks, and settings"
        case .cold: "Disks and settings"
        }
    }
}
