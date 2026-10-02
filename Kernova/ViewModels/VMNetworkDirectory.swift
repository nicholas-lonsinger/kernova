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

    /// The file's payload.
    private struct File: Codable {
        var networks: [VMNamedNetwork]
    }

    /// Every named network, ordered by name.
    private(set) var networks: [VMNamedNetwork] = []

    /// Why the file could not be read, `nil` when it was, or holds nothing
    /// yet. While set, every change is refused, so the unread file is never
    /// overwritten.
    private(set) var readFailure: String?

    /// The file the networks persist in, `nil` to keep them in memory only.
    @ObservationIgnored private let fileURL: URL?

    /// The networks `fileURL` holds — none when there is no file yet.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            networks = Self.ordered(try JSONDecoder().decode(File.self, from: data).networks)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        } catch {
            readFailure = error.localizedDescription
            #log(
                Self.logger, .error,
                "Couldn't read the named networks at \(fileURL.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Reads

    /// The network `id` identifies, `nil` when the library lists none.
    func network(withID id: UUID) -> VMNamedNetwork? {
        networks.first { $0.id == id }
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

    /// The network `text` names — by identifier, or by name ignoring case —
    /// `nil` when the library lists none.
    func network(named text: String) -> VMNamedNetwork? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: trimmed), let network = network(withID: id) { return network }
        return networks.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// The network `text` names, refusing a name the library lists none by.
    func requireNetwork(named text: String) throws -> VMNamedNetwork {
        guard let network = network(named: text) else {
            throw CommandError.itemNotFoundOnHost(item: "network named \u{201C}\(text)\u{201D}")
        }
        return network
    }

    // MARK: - Changes

    /// Lists a new network of `kind` named `name`.
    @discardableResult
    func create(name: String, kind: VmnetNetworkKind, verb: VMVerb) throws -> VMNamedNetwork {
        let network = VMNamedNetwork(id: UUID(), name: try validatedName(name, for: nil), kind: kind)
        try commit(networks + [network], verb: verb)
        return network
    }

    /// Renames the network `id` identifies. A VM names it by identifier, so
    /// no VM changes.
    func rename(_ id: UUID, to name: String, verb: VMVerb) throws {
        let name = try validatedName(name, for: id)
        try commit(
            networks.map { network in
                guard network.id == id else { return network }
                var renamed = network
                renamed.name = name
                return renamed
            }, verb: verb)
    }

    /// Stops listing the network `id` identifies.
    func remove(_ id: UUID, verb: VMVerb) throws {
        try commit(networks.filter { $0.id != id }, verb: verb)
    }

    /// `name` trimmed, refusing one that cannot name a network beside the
    /// others — `id`'s own name excepted.
    ///
    /// A membership value reads `common`, `isolated` or an identifier before
    /// a name, so a name spelling one of those could never be chosen.
    private func validatedName(_ name: String, for id: UUID?) throws -> String {
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

    /// Writes `candidate` to the file, and lists it once the write lands.
    private func commit(_ candidate: [VMNamedNetwork], verb: VMVerb) throws {
        if let readFailure {
            throw CommandError.operationFailed(
                verb: verb,
                message: "Kernova couldn\u{2019}t read its list of networks, so it changes none: \(readFailure)")
        }
        let ordered = Self.ordered(candidate)
        if let fileURL {
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(File(networks: ordered)).write(to: fileURL, options: .atomic)
            } catch {
                throw CommandError.operationFailed(
                    verb: verb,
                    message: "Kernova couldn\u{2019}t save its list of networks: \(error.localizedDescription)")
            }
        }
        networks = ordered
    }

    private static func ordered(_ networks: [VMNamedNetwork]) -> [VMNamedNetwork] {
        networks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
