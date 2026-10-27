import Foundation
import KernovaCommandModel

extension NetworkModeChoice {
    package init(_ configuration: VMConfiguration) {
        switch configuration.effectiveNetworkMode {
        case nil: self = .none
        case .nat: self = .vmnet(.nat, configuration.networkMembership)
        case .hostOnly: self = .vmnet(.hostOnly, configuration.networkMembership)
        case .bridged: self = .bridged(configuration.bridgedInterfaceIdentifier)
        }
    }

    /// The mode this choice puts the VM in, `nil` for None.
    var mode: VMNetworkMode? {
        switch self {
        case .vmnet(let kind, _): kind.mode
        case .none: nil
        case .bridged: .bridged
        }
    }

    /// How this choice names itself: its mode's group, and its entry within
    /// that group. `networks` is the library's named networks.
    ///
    /// A network this build cannot attach (`attachable` false) still names
    /// itself, marked unavailable: the picker offers no entry for it, so this
    /// is what shows a VM already on it what it is set to.
    package func label(
        attachable: Bool, interfaces: [BridgedInterface], networks: VMNetworkDirectory.State
    ) -> NetworkChoiceLabel {
        let entry: String
        switch self {
        case .vmnet(let kind, let membership):
            switch membership {
            case .common:
                entry = Self.commonTitle
            case .isolated:
                entry = Self.isolatedTitle
            case .network(let id):
                // A network the library can't name — unlisted in this mode,
                // or the list unreadable — is one no surface can choose, so
                // it never reads as merely unavailable.
                switch VMNetworkName(id, kind: kind, in: networks) {
                case .named(let name): entry = name
                case .unlisted: return NetworkChoiceLabel(mode: kind.mode, entry: Self.unlistedNetworkTitle)
                case .unreadable: return NetworkChoiceLabel(mode: kind.mode, entry: Self.unreadableNetworkListTitle)
                }
            }
        case .none:
            return .noNetwork
        case .bridged(nil):
            entry = "Automatic"
        case .bridged(.some(let identifier)):
            guard let interface = interfaces.first(where: { $0.identifier == identifier }) else {
                return NetworkChoiceLabel(mode: .bridged, entry: identifier).markedUnavailable
            }
            entry = Self.interfaceTitle(interface)
        }
        let label = NetworkChoiceLabel(mode: mode, entry: entry)
        return attachable ? label : label.markedUnavailable
    }

    /// How `config`'s network names itself on every surface naming it: the
    /// Mode picker, the Network card, and the sidebar's network filter and
    /// groups. `interfaces` is asked only when the choice names a host
    /// interface.
    static func label(
        of config: VMConfiguration, entitlements: EntitlementService,
        interfaces: () -> [BridgedInterface], networks: VMNetworkDirectory.State
    ) -> NetworkChoiceLabel {
        let choice = NetworkModeChoice(config)
        return choice.label(
            attachable: config.joinedNetwork.map(entitlements.canAttach) ?? true,
            interfaces: choice.namesAHostInterface ? interfaces() : [],
            networks: networks)
    }

    /// The entry naming a mode's common network.
    package static let commonTitle = "Common"
    /// The entry naming a network of the VM's own in its mode.
    package static let isolatedTitle = "Isolated"
    /// How a VM naming a network the library does not list names it.
    static let unlistedNetworkTitle = "Network Not in This Library"

    /// How one bridgeable interface reads in the picker — `Wi-Fi (en0)`, or the
    /// bare identifier when the host names it nothing else.
    static func interfaceTitle(_ interface: BridgedInterface) -> String {
        guard interface.localizedDisplayName != interface.identifier else {
            return interface.identifier
        }
        return "\(interface.localizedDisplayName) (\(interface.identifier))"
    }
}

/// How a network choice names itself: the mode it is grouped under — the
/// Mode menu's section header — and its entry within that group.
///
/// A menu entry reads ``entry`` alone; every one-line surface reads ``text``.
package struct NetworkChoiceLabel: Equatable, Sendable {
    /// The group's title, `nil` for the choice no mode groups (None).
    package let group: String?
    package let entry: String

    init(mode: VMNetworkMode?, entry: String) {
        self.init(group: mode?.title, entry: entry)
    }

    private init(group: String?, entry: String) {
        self.group = group
        self.entry = entry
    }

    /// The label of the choice that gives the VM no network device.
    package static let noNetwork = NetworkChoiceLabel(mode: nil, entry: "None")

    /// The label as one line of plain text: `NAT – Isolated`, or the entry
    /// alone when no group holds it.
    package var text: String {
        group.map { "\($0) \u{2013} \(entry)" } ?? entry
    }

    /// The label marked as naming a network this build cannot attach.
    var markedUnavailable: NetworkChoiceLabel {
        NetworkChoiceLabel(group: group, entry: entry + " (unavailable)")
    }
}

extension GuestIPAddress {
    /// The address as a surface states it, `nil` where there is nothing to say.
    package var displayText: String? {
        switch self {
        case .unavailable: nil
        case .externallyAssigned: "Assigned by your network"
        case .notObserved: "Not seen on the network"
        case .observed(let address): address
        }
    }
}
