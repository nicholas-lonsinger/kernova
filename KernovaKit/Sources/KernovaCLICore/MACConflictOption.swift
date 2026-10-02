import ArgumentParser
import KernovaKit

/// `--resolve-mac-conflict`: the change to a virtual machine's network that a
/// bring-up refused over its MAC address takes.
///
/// Its own group, carried by every verb that brings a guest up, so the flag
/// reads the same on each.
struct MACConflictOption: ParsableArguments {
    /// The change, as a command line spells it.
    @Option(
        name: .customLong("resolve-mac-conflict"),
        help: ArgumentHelp(
            "When another active virtual machine uses this one's MAC address on the same "
                + "network, change this one first: own-network (a network of its own), "
                + "new-address, or no-network. The last two discard a saved state.",
            valueName: "change"))
    var spelling: MACConflictSpelling?

    /// The remedy this line asks for, `nil` for none.
    var remedy: MACAddressRemedy? { spelling?.remedy }
}

/// How a command line spells each ``MACAddressRemedy``.
enum MACConflictSpelling: String, ExpressibleByArgument, CaseIterable {
    case ownNetwork = "own-network"
    case newAddress = "new-address"
    case noNetwork = "no-network"

    /// The spelling of `remedy`.
    init(_ remedy: MACAddressRemedy) {
        switch remedy {
        case .ownNetwork: self = .ownNetwork
        case .newAddress: self = .newAddress
        case .noNetwork: self = .noNetwork
        }
    }

    /// The remedy this spelling names.
    var remedy: MACAddressRemedy {
        switch self {
        case .ownNetwork: .ownNetwork
        case .newAddress: .newAddress
        case .noNetwork: .noNetwork
        }
    }
}
