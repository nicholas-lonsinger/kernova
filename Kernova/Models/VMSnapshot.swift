import KernovaKit
import Foundation

/// What a snapshot captured, which decides what reverting to it produces.
enum VMSnapshotKind: String, Codable, Sendable {
    /// The guest's memory as a VZ saved state, plus a copy of the bundle's
    /// disks and the VM's configuration. Reverting lands the VM suspended on
    /// that memory image, or running when it was live.
    case warm
    /// The bundle's disks and the VM's configuration, taken while the VM was
    /// stopped. Reverting lands the VM stopped.
    case cold
}

/// How a capture — a snapshot, or a clone's copy — started right now would be
/// taken, which decides the work it does and, for a snapshot, the
/// ``VMSnapshotKind`` it produces.
enum VMCaptureMode: Sendable, Equatable {
    /// A live `VZVirtualMachine` (running or live-paused) is paused while its
    /// disks are copied, and may write a fresh saved state inside that pause.
    case live
    /// The bundle's suspend slot is cloned — no VZ work, and the slot stays in place.
    case suspended
    /// The disks and configuration, from a stopped VM.
    case stopped

    var kind: VMSnapshotKind { self == .stopped ? .cold : .warm }
}

/// What a capture is asked to take. The kind is not part of it: the capture
/// operation's ``VMCaptureMode`` decides it.
struct VMSnapshotCaptureRequest: Sendable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var createdAt: Date
    /// Free-form user note, empty when none was entered.
    var notes: String

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), notes: String = "") {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.notes = notes
    }

    /// The manifest record of this request captured in `mode`.
    func record(capturedIn mode: VMCaptureMode) -> VMSnapshotRecord {
        VMSnapshotRecord(id: id, name: name, createdAt: createdAt, notes: notes, kind: mode.kind)
    }
}

/// One named restore point as `Snapshots/manifest.json` records it, before
/// there is a configuration it was taken under.
struct VMSnapshotRecord: Codable, Sendable, Equatable, Identifiable {
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
        self.kind = try c.decode(VMSnapshotKind.self, forKey: .kind, default: .warm, in: decoder)
    }
}

/// One named restore point: a point-in-time copy of the VM's bundle-owned
/// disks, paired with the guest's memory when the VM was live or suspended at
/// capture (``VMSnapshotKind``), kept until the user deletes it.
///
/// Distinct from the suspend slot (`VMBundleLayout.saveFileURL`), whose saved
/// state is consumed the moment a restore succeeds.
///
/// Equality covers ``network``: two values that differ in it describe
/// different captured states, and its address is what reserves it.
struct VMSnapshot: Sendable, Equatable, Identifiable {
    /// What the manifest records.
    var record: VMSnapshotRecord

    /// The network device of the configuration the snapshot was captured
    /// under, which a revert puts the VM back on — `nil` when the snapshot
    /// holds no readable configuration.
    ///
    /// Read from the snapshot's own `config.json`, which is the only place it
    /// is stored; the manifest does not repeat it.
    let network: VMCapturedNetwork?

    init(_ record: VMSnapshotRecord, network: VMCapturedNetwork?) {
        self.record = record
        self.network = network
    }

    /// The MAC address a revert puts the VM back on, which stays this VM's
    /// while the snapshot is listed (``VMMACAddressRegistry``).
    var macAddress: String? { network?.macAddress }

    var id: UUID { record.id }
    var createdAt: Date { record.createdAt }
    var kind: VMSnapshotKind { record.kind }

    var name: String {
        get { record.name }
        set { record.name = newValue }
    }

    /// Free-form user note, empty when none was entered.
    var notes: String {
        get { record.notes }
        set { record.notes = newValue }
    }
}

/// The network device a snapshot's configuration was captured with — the part
/// of what a revert installs that decides which network the VM lands on, and
/// under which address.
struct VMCapturedNetwork: Sendable, Equatable, Codable {
    var networkEnabled: Bool
    var networkMode: VMNetworkMode
    var networkMembership: VMNetworkMembership
    var bridgedInterfaceIdentifier: String?
    var macAddress: String?

    init(
        networkEnabled: Bool, networkMode: VMNetworkMode,
        networkMembership: VMNetworkMembership, bridgedInterfaceIdentifier: String?,
        macAddress: String?
    ) {
        self.networkEnabled = networkEnabled
        self.networkMode = networkMode
        self.networkMembership = networkMembership
        self.bridgedInterfaceIdentifier = bridgedInterfaceIdentifier
        self.macAddress = macAddress
    }

    /// What `configuration` carries.
    init(_ configuration: VMConfiguration) {
        self.init(
            networkEnabled: configuration.networkEnabled, networkMode: configuration.networkMode,
            networkMembership: configuration.networkMembership,
            bridgedInterfaceIdentifier: configuration.bridgedInterfaceIdentifier,
            macAddress: configuration.macAddress)
    }

    private enum CodingKeys: String, CodingKey {
        case networkEnabled, networkMode, networkMembership, bridgedInterfaceIdentifier, macAddress
    }

    /// Each field read on its own, falling back to what
    /// ``VMConfiguration``'s decoding falls back to, so a configuration that
    /// no longer decodes whole still reserves its address.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        networkEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .networkEnabled)) ?? false
        networkMode = (try? c.decodeIfPresent(VMNetworkMode.self, forKey: .networkMode)) ?? .shared
        networkMembership =
            (try? c.decodeIfPresent(VMNetworkMembership.self, forKey: .networkMembership)) ?? .common
        bridgedInterfaceIdentifier =
            (try? c.decodeIfPresent(String.self, forKey: .bridgedInterfaceIdentifier)) ?? nil
        macAddress = (try? c.decodeIfPresent(String.self, forKey: .macAddress)) ?? nil
    }

    /// `configuration` with this network device in place of its own — the
    /// network a revert to the snapshot lands `configuration`'s VM on
    /// (``VMConfiguration/adoptingSnapshotState(_:)`` installs these fields
    /// with the rest of the captured configuration).
    func installed(on configuration: VMConfiguration) -> VMConfiguration {
        var landing = configuration
        landing.networkEnabled = networkEnabled
        landing.networkMode = networkMode
        landing.networkMembership = networkMembership
        landing.bridgedInterfaceIdentifier = bridgedInterfaceIdentifier
        landing.macAddress = macAddress
        return landing
    }
}

/// The `Snapshots/manifest.json` payload.
struct VMSnapshotManifestRecord: Codable, Sendable, Equatable {
    var snapshots: [VMSnapshotRecord]
    var currentID: UUID?
}

/// Every snapshot a VM bundle holds, plus which one the VM was last taken from
/// or reverted to.
struct VMSnapshotManifest: Sendable, Equatable {
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

    /// The manifest as the file records it.
    var record: VMSnapshotManifestRecord {
        VMSnapshotManifestRecord(snapshots: snapshots.map(\.record), currentID: currentID)
    }

    /// Newest first — the list order every surface renders.
    var ordered: [VMSnapshot] {
        snapshots.sorted { $0.createdAt > $1.createdAt }
    }

    var isEmpty: Bool { snapshots.isEmpty }

    func snapshot(id: UUID) -> VMSnapshot? {
        snapshots.first { $0.id == id }
    }

    /// The snapshot an Ephemeral Mode enable pins as the baseline: the choice
    /// already recorded while it still lists, else the one the VM's state
    /// descends from, else the newest — and `nil` when there is nothing to fall
    /// back to, which is what bars the mode.
    ///
    /// Every surface that turns the mode on resolves the baseline through this,
    /// so none of them can pin a different one.
    func defaultEphemeralBaseline(preferring chosen: UUID?) -> UUID? {
        if let chosen, snapshot(id: chosen) != nil { return chosen }
        if let currentID, snapshot(id: currentID) != nil { return currentID }
        return ordered.first?.id
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

    /// Replaces the notes on the snapshot carrying `id`; a no-op when it isn't
    /// listed.
    mutating func setNotes(id: UUID, to notes: String) {
        guard let index = snapshots.firstIndex(where: { $0.id == id }) else { return }
        snapshots[index].notes = notes
    }
}
