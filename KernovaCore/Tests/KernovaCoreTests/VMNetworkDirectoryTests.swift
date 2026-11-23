import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

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
}
