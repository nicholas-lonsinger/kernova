import Foundation

/// How a caller names one virtual machine.
///
/// Display names are not unique, so a name that matches more than one VM
/// resolves to an ambiguity refusal carrying every candidate rather than to a
/// guess.
public enum VMSelector: Codable, Sendable, Hashable {
    /// The VM's stable identifier.
    case id(UUID)
    /// The VM's display name, matched whole and without regard to case.
    case name(String)
    /// Text typed by a user: read as an identifier when it parses as one and
    /// names a VM, otherwise as a display name.
    case idOrName(String)

    /// How this selector reads back in a message to the user.
    public var displayText: String {
        switch self {
        case .id(let id): id.uuidString
        case .name(let name), .idOrName(let name): name
        }
    }
}

/// How a stop, or the stop half of a restart, takes the guest down.
public enum StopDisposition: String, Codable, Sendable, Hashable, CaseIterable {
    /// Request an ACPI shutdown and let the guest power itself off.
    case graceful
    /// Terminate the virtual machine immediately, losing anything in the guest
    /// that isn’t saved to disk.
    case force
    /// Ask the guest's OS to shut down without waiting for apps, which quit
    /// without being asked to save: what a macOS guest's agent installed
    /// "For everyone" serves.
    case anyway
}

extension StopDisposition {
    /// What a force stop loses, as a sentence: only what isn’t on disk yet, so a
    /// document its app autosaved comes back.
    public static let forceLossSentence = "Anything in the guest that isn\u{2019}t saved to disk will be lost."
    /// The same, as the object of a clause: "…, which loses \(forceLoss)."
    public static let forceLoss = "anything in the guest that isn\u{2019}t saved to disk"
}

/// What a clone is of its source.
public enum CloneOutcome: String, Codable, Sendable, Hashable, CaseIterable {
    /// A machine of its own: a fresh machine identity and MAC address, so it
    /// runs beside its source, with no snapshots and Ephemeral Mode off.
    case newMachine
    /// The source's machine identity and MAC address, so it is the same machine
    /// to its guest and its network. The two never run on the same network at
    /// once, and run at once only when one is started anyway. It carries its
    /// source's snapshots, Ephemeral Mode and display preferences, but not
    /// start at launch.
    case exactCopy
}

/// What two VMs collide on.
public enum ConflictReason: Codable, Sendable, Hashable {
    /// The two share a machine identity. `overrideSettingOn` is whether
    /// Settings ▸ Advanced offers starting anyway; the refusal names that
    /// setting only while it is off.
    case machineIdentity(overrideSettingOn: Bool)
    /// Two VMs would run at once on one network with one address, which both
    /// of them already carry.
    case macAddress
    /// Other VMs in the library already hold `address`, whatever state any is
    /// in — the uniqueness every writer of an address preserves. It travels
    /// here because it is the address the caller asked for, which the VM being
    /// refused does not carry: nothing else in the refusal names which one
    /// collided.
    ///
    /// `holding` is how the refusal's other VM holds it, and `otherHolders`
    /// every further VM that does, in library order.
    case macAddressInUse(
        address: String, holding: MACAddressHolding, otherHolders: [MACAddressHolder])
    /// The VM being refused would use a disk image `other` uses, and several
    /// active VMs may use one at once only when none can write to it.
    /// `label` is the entry's label on the VM being refused; `writableThere`
    /// is whether `other` can write to it — when it can't, the VM being
    /// refused would.
    case diskImage(label: String, writableThere: Bool)
}

/// How one VM holds a MAC address: in its configuration, in snapshots taken
/// with it — each of which a revert puts back on it — or both.
public enum MACAddressHolding: Codable, Sendable, Hashable {
    case configuration
    case snapshots(HeldSnapshots)
    case configurationAndSnapshots(HeldSnapshots)

    /// The holding `configured` and `snapshots` describe, or `nil` when they
    /// describe none.
    public init?(configured: Bool, snapshots: [HeldSnapshot]) {
        switch (configured, HeldSnapshots(snapshots)) {
        case (true, nil): self = .configuration
        case (false, let held?): self = .snapshots(held)
        case (true, let held?): self = .configurationAndSnapshots(held)
        case (false, nil): return nil
        }
    }
}

/// The snapshots of one VM taken with a MAC address — at least one.
public struct HeldSnapshots: Codable, Sendable, Hashable {
    /// The first of them, in the order they were taken.
    public let first: HeldSnapshot
    /// The others, in the order they were taken.
    public let rest: [HeldSnapshot]

    /// `first`, then `rest`.
    public init(_ first: HeldSnapshot, _ rest: [HeldSnapshot] = []) {
        self.first = first
        self.rest = rest
    }

    /// `snapshots`, or `nil` when there are none.
    public init?(_ snapshots: [HeldSnapshot]) {
        guard let first = snapshots.first else { return nil }
        self.init(first, Array(snapshots.dropFirst()))
    }

    /// Every one of them, in the order they were taken.
    public var all: [HeldSnapshot] { [first] + rest }
}

/// One snapshot taken with a MAC address.
public struct HeldSnapshot: Codable, Sendable, Hashable {
    /// What the user called it.
    public let name: String
    /// Whether it is its VM's Ephemeral Mode baseline, which cannot be
    /// deleted while the mode is on.
    public let isEphemeralBaseline: Bool

    /// Names one snapshot.
    public init(name: String, isEphemeralBaseline: Bool) {
        self.name = name
        self.isEphemeralBaseline = isEphemeralBaseline
    }
}

/// A VM holding a MAC address beyond the one a refusal names, and how.
public struct MACAddressHolder: Codable, Sendable, Hashable {
    /// The VM's display name.
    public let name: String
    /// How it holds the address.
    public let holding: MACAddressHolding

    /// Names one holder.
    public init(name: String, holding: MACAddressHolding) {
        self.name = name
        self.holding = holding
    }
}
