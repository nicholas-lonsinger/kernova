import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMOrganizationDirectory Tests", .caseScoped)
@MainActor
struct VMOrganizationDirectoryTests {
    private let scratch = TestScratchDirectory(prefix: "VMOrganizationDirectoryTests")

    private var fileURL: URL { scratch.url.appendingPathComponent("Organization.json") }

    /// The file as it stands on disk, its smart group named `name`.
    private func fixture(named name: String) -> String {
        """
        {
          "folders" : [
            {
              "id" : "6F1D7E2C-0000-4000-8000-000000000002",
              "members" : [ "6F1D7E2C-0000-4000-8000-0000000000AA", "6F1D7E2C-0000-4000-8000-0000000000BB" ],
              "name" : "Clients"
            }
          ],
          "sectionOrder" : [
            "folder:6F1D7E2C-0000-4000-8000-000000000002",
            "virtualMachines",
            "smartGroup:6F1D7E2C-0000-4000-8000-000000000001"
          ],
          "smartGroups" : [
            {
              "filter" : {
                "ephemeralOnly" : true,
                "guestAgents" : [ "upToDate" ],
                "guestOSes" : [ "macOS" ],
                "networks" : [ "nat:common", "unlisted" ],
                "states" : [ "running" ],
                "tags" : [ "6F1D7E2C-0000-4000-8000-000000000003" ],
                "withSnapshotsOnly" : false
              },
              "id" : "6F1D7E2C-0000-4000-8000-000000000001",
              "name" : "\(name)"
            }
          ],
          "tags" : [
            {
              "color" : "blue",
              "id" : "6F1D7E2C-0000-4000-8000-000000000003",
              "name" : "Work"
            }
          ]
        }
        """
    }

    private func parsed(_ data: Data) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    @Test("The file reads and writes exactly the fixture's shape")
    func fileMatchesFixture() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        try Data(fixture(named: "Old").utf8).write(to: fileURL)
        let directory = VMOrganizationDirectory(fileURL: fileURL)
        let id = try #require(UUID(uuidString: "6F1D7E2C-0000-4000-8000-000000000001"))
        #expect(
            directory.state.listed?.sections.map(\.id) == [
                .folder(try #require(UUID(uuidString: "6F1D7E2C-0000-4000-8000-000000000002"))), .library,
                .smartGroup(id),
            ])
        let shared = VMLibraryFilter.Network(.nat) { _, _ in true }
        let work = try #require(UUID(uuidString: "6F1D7E2C-0000-4000-8000-000000000003"))
        #expect(
            directory.smartGroups == [
                VMSmartGroup(
                    id: id, name: "Old",
                    filter: VMLibraryFilter(
                        guestOSes: [.macOS], states: [.running], networks: [shared, .unlisted],
                        guestAgents: [.upToDate], ephemeralOnly: true, tags: [work]))
            ])
        #expect(directory.tags == [VMTag(id: work, name: "Work", color: .blue)])
        #expect(
            directory.folders == [
                VMFolder(
                    id: try #require(UUID(uuidString: "6F1D7E2C-0000-4000-8000-000000000002")), name: "Clients",
                    members: [
                        try #require(UUID(uuidString: "6F1D7E2C-0000-4000-8000-0000000000AA")),
                        try #require(UUID(uuidString: "6F1D7E2C-0000-4000-8000-0000000000BB")),
                    ])
            ])

        try directory.renameSmartGroup(id, to: "Lab Macs")

        #expect(try parsed(Data(contentsOf: fileURL)) == parsed(Data(fixture(named: "Lab Macs").utf8)))
    }

    @Test("A file holding only smart groups reads with no folders, and keeps its groups as a folder is added")
    func smartGroupsOnlyFileReadsWithNoFolders() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let full = try #require(try parsed(Data(fixture(named: "Old").utf8)).mutableCopy() as? NSMutableDictionary)
        full.removeObject(forKey: "folders")
        full.removeObject(forKey: "sectionOrder")
        try JSONSerialization.data(withJSONObject: full).write(to: fileURL)
        let directory = VMOrganizationDirectory(fileURL: fileURL)
        #expect(directory.state.unreadable == nil)
        #expect(directory.smartGroups?.map(\.name) == ["Old"])
        #expect(directory.folders == [])

        let member = try #require(UUID(uuidString: "6F1D7E2C-0000-4000-8000-0000000000AA"))
        let folder = try directory.createFolder(named: "Clients", members: [member])

        full["folders"] = [["id": folder.id.uuidString, "members": [member.uuidString], "name": "Clients"]]
        full["sectionOrder"] = [
            "smartGroup:6F1D7E2C-0000-4000-8000-000000000001", "virtualMachines", "folder:\(folder.id.uuidString)",
        ]
        #expect(try parsed(Data(contentsOf: fileURL)) == full)
    }

    @Test("A file that cannot be read is never overwritten")
    func anUnreadableFileRefusesChanges() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        let directory = VMOrganizationDirectory(fileURL: fileURL)

        #expect(directory.state.unreadable != nil)
        #expect(throws: VMOrganizationDirectory.ChangeError.self) {
            try directory.createSmartGroup(named: "Lab", filter: VMLibraryFilter())
        }
        #expect(try Data(contentsOf: fileURL) == Data("not json".utf8))
    }

    @Test("Two copies sharing the file change it rather than overwrite each other")
    func twoCopiesKeepEachOthersGroups() throws {
        let first = VMOrganizationDirectory(fileURL: fileURL)
        let second = VMOrganizationDirectory(fileURL: fileURL)
        let lab = try first.createSmartGroup(named: "Lab", filter: VMLibraryFilter())
        try second.createSmartGroup(named: "Bench", filter: VMLibraryFilter())
        #expect(second.smartGroups?.map(\.name) == ["Lab", "Bench"])
        // A name the other copy took is refused, though this one never saw it.
        #expect(throws: VMOrganizationDirectory.ChangeError.invalidName(.taken(by: "Bench"), .smartGroup)) {
            try first.createSmartGroup(named: "bench", filter: VMLibraryFilter())
        }
        try second.setFilter(VMLibraryFilter(states: [.running]), ofSmartGroup: lab.id)

        first.reload()
        #expect(first.smartGroups?.map(\.name) == ["Lab", "Bench"])
        #expect(first.smartGroup(withID: lab.id)?.filter == VMLibraryFilter(states: [.running]))
    }
}
