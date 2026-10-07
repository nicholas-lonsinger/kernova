import Foundation

/// Which coarse state a VM is in, as a filter, a group and a Shortcuts query
/// read it.
public enum VMStateBucket: String, Codable, CaseIterable, Sendable {
    /// Live in this copy of Kernova, paused or on its way in or out included.
    case running
    /// At rest with a saved session it resumes from.
    case suspended
    /// At rest with no session — never booted and failed included.
    case stopped
    /// Held by another running copy of Kernova, whose state this copy cannot
    /// see.
    case heldByAnotherCopy
    /// A create, clone or import still writing the VM's bundle.
    case preparing

    /// The bucket a VM reporting `status` lands in.
    public init(_ status: VMStatus, heldByAnotherCopy: Bool) {
        if heldByAnotherCopy {
            self = .heldByAnotherCopy
            return
        }
        switch status {
        case .running, .paused, .starting, .restoring, .installing, .saving, .snapshotting,
            .cloning:
            self = .running
        case .suspended:
            self = .suspended
        case .stopped, .initialBoot, .error:
            self = .stopped
        }
    }

    /// The bucket a VM reporting the wire status `wireName` lands in, `nil` for
    /// a name that is neither a ``VMStatus`` nor ``VMStatus/preparingWireName``.
    public init?(wireName: String, heldByAnotherCopy: Bool) {
        if wireName == VMStatus.preparingWireName {
            self = .preparing
        } else if let status = VMStatus(rawValue: wireName) {
            self.init(status, heldByAnotherCopy: heldByAnotherCopy)
        } else {
            return nil
        }
    }

    /// What a person reads for this bucket.
    public var displayName: String {
        switch self {
        case .running: "Running"
        case .suspended: "Suspended"
        case .stopped: "Stopped"
        case .heldByAnotherCopy: VMStatus.heldByAnotherCopyDisplayName
        case .preparing: "Preparing"
        }
    }
}

/// How a macOS guest's agent stands against the one this build bundles, by
/// the version the guest last reported.
public enum VMGuestAgentBucket: String, Codable, CaseIterable, Sendable {
    case upToDate
    case olderVersion
    case neverConnected

    /// The bucket for an agent last seen reporting `lastSeenVersion` (`nil`
    /// when none ever connected), against `bundledVersion` — `nil` when the
    /// build does not know its own, which counts every reported version as up
    /// to date.
    public init(lastSeenVersion: String?, bundledVersion: String?) {
        guard let lastSeenVersion else {
            self = .neverConnected
            return
        }
        guard let bundledVersion else {
            self = .upToDate
            return
        }
        self =
            KernovaVersionComparison.isAtLeast(lastSeenVersion, bundledVersion)
            ? .upToDate : .olderVersion
    }

    /// What a person reads for this bucket.
    public var displayName: String {
        switch self {
        case .upToDate: "Up to Date"
        case .olderVersion: "Older Version"
        case .neverConnected: "Never Connected"
        }
    }
}

/// Which VMs of a library to show: per-attribute include-sets and flags,
/// ANDed together.
///
/// An empty include-set and a `false` flag constrain nothing, so the default
/// value admits every VM.
public struct VMLibraryFilter: Codable, Hashable, Sendable {
    /// What a filter reads of one VM.
    public struct Subject: Hashable, Sendable {
        /// The guest the VM runs.
        public var guestOS: VMGuestOS
        /// The coarse state the VM is in.
        public var state: VMStateBucket
        /// The network the VM is set to.
        public var network: NetworkModeChoice
        /// `nil` for a guest no Kernova agent runs in (Linux).
        public var guestAgent: VMGuestAgentBucket?
        /// Whether Ephemeral Mode is on.
        public var isEphemeral: Bool
        /// Whether the VM holds a snapshot other than its Ephemeral Mode
        /// baseline.
        public var hasSnapshots: Bool

        /// A subject reading as given.
        public init(
            guestOS: VMGuestOS, state: VMStateBucket, network: NetworkModeChoice,
            guestAgent: VMGuestAgentBucket?, isEphemeral: Bool, hasSnapshots: Bool
        ) {
            self.guestOS = guestOS
            self.state = state
            self.network = network
            self.guestAgent = guestAgent
            self.isEphemeral = isEphemeral
            self.hasSnapshots = hasSnapshots
        }
    }

    /// Admits only the guests in the set.
    public var guestOSes: Set<VMGuestOS>
    /// Admits only the state buckets in the set.
    public var states: Set<VMStateBucket>
    /// Admits only the networks in the set.
    public var networks: Set<NetworkModeChoice>
    /// Admits only guests with an agent bucket in the set, so a Linux guest
    /// never passes a non-empty one.
    public var guestAgents: Set<VMGuestAgentBucket>
    /// Admits only VMs with Ephemeral Mode on.
    public var ephemeralOnly: Bool
    /// Admits only VMs holding a snapshot other than their Ephemeral Mode
    /// baseline.
    public var withSnapshotsOnly: Bool

    /// A filter constraining each attribute given; the defaults constrain
    /// nothing.
    public init(
        guestOSes: Set<VMGuestOS> = [], states: Set<VMStateBucket> = [],
        networks: Set<NetworkModeChoice> = [], guestAgents: Set<VMGuestAgentBucket> = [],
        ephemeralOnly: Bool = false, withSnapshotsOnly: Bool = false
    ) {
        self.guestOSes = guestOSes
        self.states = states
        self.networks = networks
        self.guestAgents = guestAgents
        self.ephemeralOnly = ephemeralOnly
        self.withSnapshotsOnly = withSnapshotsOnly
    }

    /// Whether any attribute constrains the library.
    public var isActive: Bool { self != Self() }

    /// Whether `subject` passes every attribute.
    public func admits(_ subject: Subject) -> Bool {
        failedAttributes(of: subject).isEmpty
    }

    /// This filter less every attribute `subject` fails, so it admits
    /// `subject` and constrains the rest as before.
    public func admitting(_ subject: Subject) -> VMLibraryFilter {
        var relaxed = self
        for attribute in failedAttributes(of: subject) {
            switch attribute {
            case .guestOS: relaxed.guestOSes = []
            case .state: relaxed.states = []
            case .network: relaxed.networks = []
            case .guestAgent: relaxed.guestAgents = []
            case .ephemeral: relaxed.ephemeralOnly = false
            case .snapshots: relaxed.withSnapshotsOnly = false
            }
        }
        return relaxed
    }

    private enum Attribute {
        case guestOS, state, network, guestAgent, ephemeral, snapshots
    }

    private func failedAttributes(of subject: Subject) -> [Attribute] {
        var failed: [Attribute] = []
        if !guestOSes.isEmpty, !guestOSes.contains(subject.guestOS) { failed.append(.guestOS) }
        if !states.isEmpty, !states.contains(subject.state) { failed.append(.state) }
        if !networks.isEmpty, !networks.contains(subject.network) { failed.append(.network) }
        if !guestAgents.isEmpty, !(subject.guestAgent.map(guestAgents.contains) ?? false) {
            failed.append(.guestAgent)
        }
        if ephemeralOnly, !subject.isEphemeral { failed.append(.ephemeral) }
        if withSnapshotsOnly, !subject.hasSnapshots { failed.append(.snapshots) }
        return failed
    }

    private enum CodingKeys: String, CodingKey {
        case guestOSes, states, networks, guestAgents, ephemeralOnly, withSnapshotsOnly
    }

    /// A missing key reads as that attribute unconstrained.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            guestOSes: try c.decodeIfPresent(Set<VMGuestOS>.self, forKey: .guestOSes) ?? [],
            states: try c.decodeIfPresent(Set<VMStateBucket>.self, forKey: .states) ?? [],
            networks: try c.decodeIfPresent(Set<NetworkModeChoice>.self, forKey: .networks) ?? [],
            guestAgents: try c.decodeIfPresent(Set<VMGuestAgentBucket>.self, forKey: .guestAgents)
                ?? [],
            ephemeralOnly: try c.decodeIfPresent(Bool.self, forKey: .ephemeralOnly) ?? false,
            withSnapshotsOnly: try c.decodeIfPresent(Bool.self, forKey: .withSnapshotsOnly) ?? false)
    }

    /// Sets are written sorted, so equal filters encode to equal bytes.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(guestOSes.map(\.rawValue).sorted(), forKey: .guestOSes)
        try c.encode(states.map(\.rawValue).sorted(), forKey: .states)
        try c.encode(networks.map(\.rawValue).sorted(), forKey: .networks)
        try c.encode(guestAgents.map(\.rawValue).sorted(), forKey: .guestAgents)
        try c.encode(ephemeralOnly, forKey: .ephemeralOnly)
        try c.encode(withSnapshotsOnly, forKey: .withSnapshotsOnly)
    }
}
