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
        let office = try directory.create(name: " Office ", kind: .shared, verb: .createNetwork)
        let lab = try directory.create(name: "Lab", kind: .hostOnly, verb: .createNetwork)
        #expect(office.name == "Office")
        #expect(directory.networks.map(\.name) == ["Lab", "Office"])

        try directory.rename(lab.id, to: "Zoo", verb: .renameNetwork)
        let reread = VMNetworkDirectory(fileURL: fileURL)
        #expect(reread.networks.map(\.name) == ["Office", "Zoo"])
        #expect(reread.network(named: "zoo")?.id == lab.id)
        #expect(reread.network(named: lab.id.uuidString)?.kind == .hostOnly)

        try reread.remove(office.id, verb: .deleteNetwork)
        #expect(VMNetworkDirectory(fileURL: fileURL).networks.map(\.id) == [lab.id])
    }

    @Test("A name has to be new, non-empty, and not spell a membership value")
    func namesAreValidated() throws {
        let directory = VMNetworkDirectory(fileURL: nil)
        let lab = try directory.create(name: "Lab", kind: .shared, verb: .createNetwork)
        for name in ["", "  ", "LAB", "common", "Isolated", UUID().uuidString] {
            #expect(throws: CommandError.self, "\(name)") {
                try directory.create(name: name, kind: .shared, verb: .createNetwork)
            }
        }
        // Its own name, recased, is a rename.
        try directory.rename(lab.id, to: "LAB", verb: .renameNetwork)
        #expect(directory.networks.map(\.name) == ["LAB"])
    }

    @Test("A file that cannot be read is never overwritten")
    func anUnreadableFileRefusesChanges() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        let directory = VMNetworkDirectory(fileURL: fileURL)

        #expect(directory.readFailure != nil)
        #expect(throws: CommandError.self) {
            try directory.create(name: "Lab", kind: .shared, verb: .createNetwork)
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
}
