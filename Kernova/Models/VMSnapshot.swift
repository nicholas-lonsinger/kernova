import Foundation

/// What a snapshot captured, which decides what reverting to it produces.
enum VMSnapshotKind: String, Codable, Sendable {
    /// The guest's memory as a VZ saved state, plus a copy of the bundle's
    /// disks. Reverting lands the VM paused on that memory image.
    case warm
    /// The bundle's disks alone, taken while the VM was stopped. Reverting
    /// lands the VM stopped.
    case cold
}

/// How a capture started right now would be taken, which decides both the
/// work it does and the ``VMSnapshotKind`` it produces.
enum VMSnapshotCaptureMode: Sendable, Equatable {
    /// A live `VZVirtualMachine` writes a fresh saved state (running or live-paused).
    case live
    /// The bundle's suspend slot is cloned — no VZ work, and the slot stays in place.
    case suspended
    /// The disks alone, from a stopped VM.
    case stopped

    var kind: VMSnapshotKind { self == .stopped ? .cold : .warm }
}

/// One named restore point: a point-in-time copy of the VM's bundle-owned
/// disks, paired with the guest's memory when the VM was live or suspended at
/// capture (``VMSnapshotKind``), kept until the user deletes it.
///
/// Distinct from the suspend slot (`VMBundleLayout.saveFileURL`), whose saved
/// state is consumed the moment a restore succeeds.
struct VMSnapshot: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var createdAt: Date
    /// Free-form user note, empty when none was entered.
    var notes: String
    var kind: VMSnapshotKind

    init(
        id: UUID = UUID(), name: String, createdAt: Date = Date(), notes: String = "",
        kind: VMSnapshotKind = .warm
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.notes = notes
        self.kind = kind
    }

    // Custom `init(from:)` for `kind`, whose default differs from what
    // synthesized `Codable` would do: a `decode` of a non-optional field fails
    // the whole manifest when the key is absent.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.notes = try c.decode(String.self, forKey: .notes)
        self.kind = try c.decodeIfPresent(VMSnapshotKind.self, forKey: .kind) ?? .warm
    }
}

/// The `Snapshots/manifest.json` payload: every snapshot a VM bundle holds,
/// plus which one the VM was last taken from or reverted to.
struct VMSnapshotManifest: Codable, Sendable, Equatable {
    /// Storage order is the order snapshots were taken; ``ordered`` is what the
    /// UI reads.
    var snapshots: [VMSnapshot]

    /// The snapshot the VM's current state descends from, marked "Current" in
    /// the UI; `nil` once that snapshot is deleted, or before the first one is
    /// taken.
    var currentID: UUID?

    init(snapshots: [VMSnapshot] = [], currentID: UUID? = nil) {
        self.snapshots = snapshots
        self.currentID = currentID
    }

    /// Newest first — the list order every surface renders.
    var ordered: [VMSnapshot] {
        snapshots.sorted { $0.createdAt > $1.createdAt }
    }

    var isEmpty: Bool { snapshots.isEmpty }

    func snapshot(id: UUID) -> VMSnapshot? {
        snapshots.first { $0.id == id }
    }

    /// A default name for a new snapshot that doesn't collide with an existing
    /// one — `"Snapshot"`, then `"Snapshot 2"`, `"Snapshot 3"`, …
    var defaultNewName: String {
        UniqueName.firstAvailable(prefix: "Snapshot", existing: snapshots.map(\.name))
    }

    /// Adds `snapshot` and marks it current.
    mutating func insert(_ snapshot: VMSnapshot) {
        snapshots.append(snapshot)
        currentID = snapshot.id
    }

    /// Drops the snapshot carrying `id`, clearing the current marker when it
    /// named the removed one.
    mutating func remove(id: UUID) {
        snapshots.removeAll { $0.id == id }
        if currentID == id { currentID = nil }
    }

    /// Renames the snapshot carrying `id`; a no-op when it isn't listed.
    mutating func rename(id: UUID, to name: String) {
        guard let index = snapshots.firstIndex(where: { $0.id == id }) else { return }
        snapshots[index].name = name
    }
}
