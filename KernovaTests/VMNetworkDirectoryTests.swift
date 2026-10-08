import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("VMNetworkDirectory Tests", .caseScoped)
@MainActor
struct VMNetworkDirectoryTests {
    private let scratch = TestScratchDirectory(prefix: "VMNetworkDirectoryTests")

    private var fileURL: URL { scratch.url.appendingPathComponent("Networks.json") }

    @Test("Networks persist, ordered by name, and a rename keeps the identifier")
    func networksPersistAcrossLaunches() throws {
        let directory = VMNetworkDirectory(fileURL: fileURL)
        let office = try directory.create(name: " Office ", kind: .nat, verb: .createNetwork)
        let lab = try directory.create(name: "Lab", kind: .hostOnly, verb: .createNetwork)
        #expect(office.name == "Office")
        #expect(directory.state.listed?.map(\.name) == ["Lab", "Office"])

        try directory.rename(lab.id, to: "Zoo", verb: .renameNetwork)
        let reread = VMNetworkDirectory(fileURL: fileURL)
        #expect(reread.state.listed?.map(\.name) == ["Office", "Zoo"])
        #expect(reread.network(named: "zoo")?.id == lab.id)
        #expect(reread.network(named: lab.id.uuidString)?.kind == .hostOnly)

        try reread.remove(office.id, verb: .deleteNetwork)
        #expect(VMNetworkDirectory(fileURL: fileURL).state.listed?.map(\.id) == [lab.id])
    }

    @Test("A name has to be new, non-empty, and not spell a membership value")
    func namesAreValidated() throws {
        let directory = VMNetworkDirectory(fileURL: nil)
        let lab = try directory.create(name: "Lab", kind: .nat, verb: .createNetwork)
        for name in ["", "  ", "LAB", "common", "Isolated", UUID().uuidString] {
            #expect(throws: CommandError.self, "\(name)") {
                try directory.create(name: name, kind: .nat, verb: .createNetwork)
            }
        }
        // Its own name, recased, is a rename.
        try directory.rename(lab.id, to: "LAB", verb: .renameNetwork)
        #expect(directory.state.listed?.map(\.name) == ["LAB"])
    }

    @Test("A file that cannot be read is never overwritten")
    func anUnreadableFileRefusesChanges() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        let directory = VMNetworkDirectory(fileURL: fileURL)

        #expect(directory.state.listed == nil)
        #expect(throws: CommandError.self) {
            try directory.create(name: "Lab", kind: .nat, verb: .createNetwork)
        }
        #expect(try Data(contentsOf: fileURL) == Data("not json".utf8))
    }

    @Test("The network a VM joins is listed only in the network's own mode")
    func theJoinedNetworkMatchesItsKind() throws {
        let directory = VMNetworkDirectory(fileURL: nil)
        let lab = try directory.create(name: "Lab", kind: .hostOnly, verb: .createNetwork)
        var config = VMConfiguration(name: "Member", guestOS: .linux, bootMode: .efi)
        config.networkMembership = .network(lab.id)

        #expect(directory.network(joinedBy: config) == nil)
        config.networkMode = .hostOnly
        #expect(directory.network(joinedBy: config) == lab)
        config.networkEnabled = false
        #expect(directory.network(joinedBy: config) == nil)
    }

    @Test("Two copies sharing the file change it rather than overwrite each other")
    func twoCopiesKeepEachOthersNetworks() throws {
        let first = VMNetworkDirectory(fileURL: fileURL)
        let second = VMNetworkDirectory(fileURL: fileURL)
        try first.create(name: "Lab", kind: .nat, verb: .createNetwork)
        try second.create(name: "Bench", kind: .hostOnly, verb: .createNetwork)
        #expect(second.state.listed?.map(\.name) == ["Bench", "Lab"])
        // A name the other copy took is refused, though this one never saw it.
        #expect(throws: CommandError.self) {
            try first.create(name: "bench", kind: .nat, verb: .createNetwork)
        }
        first.reload()
        #expect(first.state.listed?.map(\.name) == ["Bench", "Lab"])
    }

    @Test("A network in the list that doesn't decode is removed alone, and the rest are kept")
    func aBadNetworkIsRepairedAlone() throws {
        let kept = UUID()
        let data = Data(
            #"""
            {"networks": [{"id": "\#(kept.uuidString)", "name": "Lab", "kind": "nat"},
                          {"name": "Nameless", "kind": "hostOnly"}]}
            """#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VMNetworkDirectory.File.self, from: data)
        }
        let diagnosis = ConfigFileDiagnosis(
            decoding: VMNetworkDirectory.File.self, from: data, decoder: JSONDecoder(), encoder: JSONEncoder())

        #expect(diagnosis.problems.map(\.path?.description) == ["$.networks[1]"])
        #expect(diagnosis.problems.map(\.repair) == [.removeEntry])
        let repaired = try JSONDecoder().decode(
            VMNetworkDirectory.File.self, from: try #require(diagnosis.repaired))
        #expect(repaired.networks.map(\.id) == [kept])
    }

    @Test("A reload that reads what the last one read changes nothing an observer sees")
    func anUnchangedReloadIsNoChange() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        for bytes in [Data("not json".utf8), Data(#"{"networks": []}"#.utf8)] {
            try bytes.write(to: fileURL)
            let directory = VMNetworkDirectory(fileURL: fileURL)
            let changed = Flag()
            withObservationTracking {
                _ = directory.state
            } onChange: {
                changed.set()
            }

            directory.reload()

            #expect(!changed.isSet)
        }
    }

    private final class Flag: @unchecked Sendable {
        private(set) var isSet = false
        func set() { isSet = true }
    }
}
