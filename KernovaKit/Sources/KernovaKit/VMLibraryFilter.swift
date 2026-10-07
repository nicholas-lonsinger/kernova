import Foundation

/// Which coarse state a VM is in, as a filter, a group and a Shortcuts query
/// read it. The app derives it from whether a session is live, not from the
/// status it reports, which names an operation without saying whether a
/// session is live.
public enum VMStateBucket: String, Codable, CaseIterable, Sendable {
    /// A session is live in this copy of Kernova, paused or under an operation
    /// included.
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
    /// A network as a filter tells networks apart: the network a VM is set
    /// to, except that every named network the library does not list is the
    /// one value ``unlisted`` — they all read "Network Not in This Library",
    /// and nothing else tells them apart.
    ///
    /// Coded as one string: ``unlisted``'s `unlisted`, else the choice's
    /// ``NetworkModeChoice/rawValue``.
    public struct Network: Hashable, Sendable, Codable {
        /// The choice, `nil` for ``unlisted``.
        public let choice: NetworkModeChoice?

        /// Every named network the library does not list.
        public static let unlisted = Network(storing: nil)

        private static let unlistedValue = "unlisted"

        private init(storing choice: NetworkModeChoice?) {
            self.choice = choice
        }

        /// `choice` as a filter tells it apart: ``unlisted`` when it names a
        /// network `isListed` does not answer for — its kind and identifier.
        public init(_ choice: NetworkModeChoice, isListed: (VmnetNetworkKind, UUID) -> Bool) {
            if case .vmnet(let kind, .network(let id)) = choice, !isListed(kind, id) {
                self = .unlisted
            } else {
                self.init(storing: choice)
            }
        }

        /// The value `rawValue` spells, `nil` for a string that spells none.
        public init?(rawValue: String) {
            if rawValue == Self.unlistedValue {
                self = .unlisted
            } else if let choice = NetworkModeChoice(rawValue: rawValue) {
                self.init(storing: choice)
            } else {
                return nil
            }
        }

        /// The coded spelling.
        public var rawValue: String { choice?.rawValue ?? Self.unlistedValue }

        /// The value `text` spells as typed: a ``rawValue`` naming no named
        /// network, or a vmnet mode alone (`shared`, `hostOnly`) for that
        /// mode's common network. `nil` for anything else — a named network
        /// is typed by its name or identifier, which only the library
        /// resolves, so no network can be named one of these.
        public init?(spelling text: String) {
            if let kind = VmnetNetworkKind(rawValue: text) {
                self.init(storing: .vmnet(kind, .common))
                return
            }
            guard let network = Self(rawValue: text) else { return nil }
            if case .vmnet(_, .network)? = network.choice { return nil }
            self = network
        }

        /// What ``init(spelling:)`` reads, but for `bridged:<interface>`, in
        /// the order the Mode picker lists them.
        public static let spellings: [String] =
            [VmnetNetworkKind.shared, .hostOnly].flatMap { kind in
                [kind.rawValue, NetworkModeChoice.vmnet(kind, .isolated).rawValue]
            }
            + [NetworkModeChoice.bridged(nil).rawValue, NetworkModeChoice.none.rawValue, unlistedValue]

        /// Reads the one string ``rawValue`` spells.
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let network = Self(rawValue: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "\(text) names no network")
            }
            self = network
        }

        /// Writes ``rawValue``.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// What a filter reads of one VM.
    public struct Subject: Hashable, Sendable {
        /// The guest the VM runs.
        public var guestOS: VMGuestOS
        /// The coarse state the VM is in.
        public var state: VMStateBucket
        /// The network the VM is set to.
        public var network: Network
        /// `nil` for a guest no Kernova agent runs in (Linux).
        public var guestAgent: VMGuestAgentBucket?
        /// Whether Ephemeral Mode is on.
        public var isEphemeral: Bool
        /// Whether the VM holds any snapshot, its Ephemeral Mode baseline
        /// included — the snapshots every surface counts.
        public var hasSnapshots: Bool

        /// A subject reading as given.
        public init(
            guestOS: VMGuestOS, state: VMStateBucket, network: Network,
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
    public var networks: Set<Network>
    /// Admits only guests with an agent bucket in the set, so a Linux guest
    /// never passes a non-empty one.
    public var guestAgents: Set<VMGuestAgentBucket>
    /// Admits only VMs with Ephemeral Mode on.
    public var ephemeralOnly: Bool
    /// Admits only VMs holding any snapshot.
    public var withSnapshotsOnly: Bool

    /// A filter constraining each attribute given; the defaults constrain
    /// nothing.
    public init(
        guestOSes: Set<VMGuestOS> = [], states: Set<VMStateBucket> = [],
        networks: Set<Network> = [], guestAgents: Set<VMGuestAgentBucket> = [],
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
            networks: try c.decodeIfPresent(Set<Network>.self, forKey: .networks) ?? [],
            guestAgents: try c.decodeIfPresent(Set<VMGuestAgentBucket>.self, forKey: .guestAgents)
                ?? [],
            ephemeralOnly: try c.decodeIfPresent(Bool.self, forKey: .ephemeralOnly) ?? false,
            withSnapshotsOnly: try c.decodeIfPresent(Bool.self, forKey: .withSnapshotsOnly) ?? false)
    }

    /// Sets are written sorted, so under `.sortedKeys` equal filters encode to
    /// equal bytes.
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
