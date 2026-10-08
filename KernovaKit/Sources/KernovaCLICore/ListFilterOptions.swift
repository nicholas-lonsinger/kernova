import ArgumentParser
import Foundation
import KernovaKit

/// The flags that narrow a listing to the VMs with given attributes — the
/// sidebar's filter, flag for attribute.
///
/// Repeating a flag widens it — a VM passes when it has any value given — and
/// different flags AND together.
struct ListFilterOptions: ParsableArguments {
    @Option(name: .customLong("os"), help: ArgumentHelp("List only guests running this OS.", valueName: "os"))
    var guestOSes: [VMGuestOS] = []

    @Option(name: .customLong("state"), help: ArgumentHelp("List only VMs in this state.", valueName: "state"))
    var states: [VMStateBucket] = []

    @Option(
        name: .customLong("network"),
        help: ArgumentHelp(
            "List only VMs on this network, ignoring case: "
                + VMLibraryFilter.Network.spellings.joined(separator: ", ")
                + ", bridged:<interface>, or a named network's name or identifier. "
                + "bridged lists VMs bridged to any interface, Automatic included; "
                + "bridged:automatic lists only Automatic.",
            valueName: "network"),
        completion: CompletionSource.networkFilter)
    var networks: [String] = []

    @Option(
        name: .customLong("agent"),
        help: ArgumentHelp(
            "List only macOS guests whose guest agent, against the one this build bundles, is this.",
            valueName: "agent"))
    var guestAgents: [VMGuestAgentBucket] = []

    @Flag(name: .customLong("ephemeral"), help: "List only VMs with Ephemeral Mode on.")
    var ephemeralOnly = false

    @Flag(name: .customLong("has-snapshots"), help: "List only VMs holding a snapshot.")
    var withSnapshotsOnly = false

    @Option(
        name: .customLong("tag"),
        help: ArgumentHelp("List only VMs carrying this tag, by name or identifier.", valueName: "tag"))
    var tags: [String] = []

    /// The filter these flags spell but for the networks and the tags, which
    /// go as typed: only the library knows its named networks and its tags.
    var filter: VMLibraryFilter {
        VMLibraryFilter(
            guestOSes: Set(guestOSes), states: Set(states), guestAgents: Set(guestAgents),
            ephemeralOnly: ephemeralOnly, withSnapshotsOnly: withSnapshotsOnly)
    }
}

/// The flags that narrow a verb to the VMs in a group: the same group whether
/// a listing or a verb acting on its members names it.
struct GroupTargetOptions: ParsableArguments {
    @Option(
        name: .customLong("smart-group"),
        help: ArgumentHelp("The VMs in this smart group, by name or identifier.", valueName: "name"),
        completion: CompletionSource.smartGroup)
    var smartGroups: [String] = []

    @Option(
        name: .customLong("folder"),
        help: ArgumentHelp("The VMs in this folder, by name or identifier.", valueName: "name"),
        completion: CompletionSource.folder)
    var folders: [String] = []

    /// Refuses a second group: repeating a filter flag widens it, while every
    /// group named narrows, so a second one would read either way.
    func validate() throws {
        guard groups.count <= 1 else {
            throw ValidationError("Name at most one smart group or folder.")
        }
    }

    /// The group these flags name, which a VM is in.
    var groups: [VMGroupReference] {
        smartGroups.map { VMGroupReference(.smartGroup, named: $0) }
            + folders.map { VMGroupReference(.folder, named: $0) }
    }
}

extension VMGuestOS: ExpressibleByArgument {}
extension VMStateBucket: ExpressibleByArgument {}
extension VMGuestAgentBucket: ExpressibleByArgument {}
extension VMLibrarySort: ExpressibleByArgument {}
