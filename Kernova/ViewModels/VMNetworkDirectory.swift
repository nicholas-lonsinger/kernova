import Foundation
import KernovaKit
import KernovaLogging

/// The library's named networks, and the one writer of the file that holds
/// them.
///
/// A network is listed here or nowhere: a VM naming one this library does not
/// list — imported from another Mac, or put back by a snapshot taken before
/// the network was deleted — still joins it, together with every other VM
/// naming it, and every surface reports it as a network the library does not
/// list.
@MainActor
@Observable
final class VMNetworkDirectory {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMNetworkDirectory")

    /// Where the library every copy of the app shares keeps its networks,
    /// beside the folder its VMs live in.
    nonisolated static let productionFileURL = URL.applicationSupportDirectory
        .appendingPathComponent("Kernova", isDirectory: true)
        .appendingPathComponent("Networks.json", isDirectory: false)

    /// What every surface that cannot list the networks tells the user.
    nonisolated static let unreadableMessage =
        "Kernova can\u{2019}t read its list of networks. Choose File > Check Config Files\u{2026} to review it."

    /// The file's payload.
    struct File: Codable, Equatable, Sendable {
        var networks: [VMNamedNetwork]
    }

    /// What the file held the last time it was read: every named network,
    /// ordered by name.
    typealias State = ConfigFileState<[VMNamedNetwork]>

    private(set) var state: State = .listed([])

    /// The file the networks persist in, `nil` to keep them in memory only.
    @ObservationIgnored nonisolated let file: CoordinatedJSONFile<File>?

    /// The networks `fileURL` holds — none when there is no file yet.
    init(fileURL: URL?) {
        self.file = fileURL.map(Self.file(at:))
        reload()
    }

    /// Reads the file again, taking in what another copy of Kernova sharing
    /// the library wrote since.
    func reload() {
        guard let file else { return }
        state = file.state { Self.ordered($0.networks) }
        if let unreadable = state.unreadable {
            #log(
                Self.logger, .error,
                "Couldn't read the named networks at \(file.url.path(percentEncoded: false), privacy: .public): \(String(describing: unreadable.problems), privacy: .public)"
            )
        }
    }

    // MARK: - Reads

    /// The networks listed, refusing as `verb` while the file cannot be read.
    func listedNetworks(verb: VMVerb) throws -> [VMNamedNetwork] {
        guard let networks = state.listed else {
            throw CommandError.operationFailed(verb: verb, message: Self.unreadableMessage)
        }
        return networks
    }

    /// The network `id` identifies, `nil` when the library lists none.
    func network(withID id: UUID) -> VMNamedNetwork? {
        state.listed?.first { $0.id == id }
    }

    /// The listed network a VM under `configuration` joins, `nil` where it
    /// joins none — a mode's common network, its own, or a named network the
    /// library does not list in the VM's mode.
    func network(joinedBy configuration: VMConfiguration) -> VMNamedNetwork? {
        guard let joined = configuration.joinedNetwork, case .vmnet(let id) = joined,
            case .named(let networkID) = id.scope, let network = network(withID: networkID),
            network.kind == id.kind
        else { return nil }
        return network
    }

    /// The named network a VM under `configuration` names, as this
    /// directory lists it — `nil` where its membership names none.
    func networkName(of configuration: VMConfiguration) -> VMNetworkName? {
        guard let id = configuration.effectiveNetworkMembership?.namedNetwork,
            let kind = VmnetNetworkKind(mode: configuration.networkMode)
        else { return nil }
        return VMNetworkName(id, kind: kind, in: state)
    }

    /// The network `text` names — by identifier, or by name ignoring case —
    /// `nil` when the library lists none.
    func network(named text: String) -> VMNamedNetwork? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: trimmed), let network = network(withID: id) { return network }
        return state.listed?.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// The network `text` names, refusing as `verb` a name the library lists
    /// none by, and every name while the file cannot be read.
    func requireNetwork(named text: String, verb: VMVerb) throws -> VMNamedNetwork {
        _ = try listedNetworks(verb: verb)
        guard let network = network(named: text) else {
            throw CommandError.itemNotFoundOnHost(item: "network named \u{201C}\(text)\u{201D}")
        }
        return network
    }

    // MARK: - Changes

    /// Lists a new network of `kind` named `name`.
    @discardableResult
    func create(name: String, kind: VmnetNetworkKind, verb: VMVerb) throws -> VMNamedNetwork {
        var created: VMNamedNetwork?
        try commit(verb: verb) { networks in
            let network = VMNamedNetwork(
                id: UUID(), name: try Self.validatedName(name, for: nil, among: networks), kind: kind)
            created = network
            return networks + [network]
        }
        guard let created else { preconditionFailure("A committed create made no network") }
        return created
    }

    /// Renames the network `id` identifies. A VM names it by identifier, so
    /// no VM changes.
    func rename(_ id: UUID, to name: String, verb: VMVerb) throws {
        try commit(verb: verb) { networks in
            let name = try Self.validatedName(name, for: id, among: networks)
            return networks.map { network in
                guard network.id == id else { return network }
                var renamed = network
                renamed.name = name
                return renamed
            }
        }
    }

    /// Stops listing the network `id` identifies.
    func remove(_ id: UUID, verb: VMVerb) throws {
        try commit(verb: verb) { networks in networks.filter { $0.id != id } }
    }

    /// `name` trimmed, refusing one that cannot name a network beside
    /// `networks` — `id`'s own name excepted.
    ///
    /// A membership value reads `common`, `isolated` or an identifier before
    /// a name, so a name spelling one of those could never be chosen.
    private static func validatedName(
        _ name: String, for id: UUID?, among networks: [VMNamedNetwork]
    ) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CommandError.invalidArgument("A network needs a name.")
        }
        let reserved = [VMNetworkMembership.commonValue, VMNetworkMembership.isolatedValue]
        guard !reserved.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }),
            UUID(uuidString: trimmed) == nil
        else {
            throw CommandError.invalidArgument(
                "\u{201C}\(trimmed)\u{201D} can\u{2019}t name a network: "
                    + "\(VMNetworkMembership.commonValue), \(VMNetworkMembership.isolatedValue) "
                    + "and identifiers already name a network membership.")
        }
        if let other = networks.first(where: {
            $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            throw CommandError.invalidArgument(
                "A network named \u{201C}\(other.name)\u{201D} already exists. Give this one another name.")
        }
        return trimmed
    }

    /// Applies `change` to the networks the file holds now and writes the
    /// result (``CoordinatedJSONFile/update(_:)``), then lists the result.
    private func commit(
        verb: VMVerb, _ change: ([VMNamedNetwork]) throws -> [VMNamedNetwork]
    ) throws {
        guard let file else {
            state = .listed(Self.ordered(try change(try listedNetworks(verb: verb))))
            return
        }
        do {
            state = .listed(
                try file.update { File(networks: Self.ordered(try change(Self.ordered($0.networks)))) }
                    .networks)
        } catch let failure as CoordinatedJSONFile<File>.Failure {
            switch failure {
            case .unreadable(let unreadable):
                state = .unreadable(unreadable)
                throw CommandError.operationFailed(verb: verb, message: Self.unreadableMessage)
            case .unsaved(let error):
                throw CommandError.operationFailed(
                    verb: verb,
                    message: "Kernova couldn\u{2019}t save its list of networks: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Repair

    /// The network list at `url`, as the library's own reads and writes take
    /// it.
    nonisolated static func file(at url: URL) -> CoordinatedJSONFile<File> {
        CoordinatedJSONFile(location: .networkList(url), owner: .networkList, empty: File(networks: []))
    }

    nonisolated private static func ordered(_ networks: [VMNamedNetwork]) -> [VMNamedNetwork] {
        networks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

extension VMNetworkName {
    /// The named network `id` of `kind` as `networks` lists it: a network
    /// listed only in the other mode is one the library does not list.
    init(_ id: UUID, kind: VmnetNetworkKind, in networks: VMNetworkDirectory.State) {
        switch networks {
        case .unreadable:
            self = .unreadable
        case .listed(let networks):
            self = networks.first { $0.id == id && $0.kind == kind }.map { .named($0.name) } ?? .unlisted(id)
        }
    }
}
