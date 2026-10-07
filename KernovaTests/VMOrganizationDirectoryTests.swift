import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("VMOrganizationDirectory Tests", .caseScoped)
@MainActor
struct VMOrganizationDirectoryTests {
    private let scratch = TestScratchDirectory(prefix: "VMOrganizationDirectoryTests")

    private var fileURL: URL { scratch.url.appendingPathComponent("Organization.json") }

    @Test("Smart groups persist in their own order, with their filters, and a rename keeps the identifier")
    func smartGroupsRoundTrip() throws {
        let directory = VMOrganizationDirectory(fileURL: fileURL)
        let running = try directory.createSmartGroup(
            named: " Running ", filter: VMLibraryFilter(states: [.running]))
        let macs = try directory.createSmartGroup(named: "Macs", filter: VMLibraryFilter(guestOSes: [.macOS]))
        let everything = try directory.createSmartGroup(named: "Everything", filter: VMLibraryFilter())
        #expect(running.name == "Running")

        try directory.renameSmartGroup(macs.id, to: "Apple")
        try directory.setFilter(VMLibraryFilter(guestOSes: [.macOS], ephemeralOnly: true), ofSmartGroup: macs.id)
        try directory.moveSmartGroup(everything.id, before: running.id)

        let reread = VMOrganizationDirectory(fileURL: fileURL)
        #expect(reread.smartGroups.map(\.name) == ["Everything", "Running", "Apple"])
        #expect(reread.smartGroups == directory.smartGroups)
        #expect(reread.smartGroup(withID: macs.id)?.filter == VMLibraryFilter(guestOSes: [.macOS], ephemeralOnly: true))
        #expect(reread.smartGroup(withID: everything.id)?.filter.isActive == false)

        try reread.moveSmartGroup(everything.id, before: nil)
        try reread.removeSmartGroup(running.id)
        #expect(VMOrganizationDirectory(fileURL: fileURL).smartGroups.map(\.id) == [macs.id, everything.id])
    }

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
          "smartGroups" : [
            {
              "filter" : {
                "ephemeralOnly" : true,
                "guestAgents" : [ "upToDate" ],
                "guestOSes" : [ "macOS" ],
                "networks" : [ "shared:common", "unlisted" ],
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
        let shared = VMLibraryFilter.Network(.shared) { _, _ in true }
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

    @Test("Folders persist in their own order, each with its members in its own order, a VM in several")
    func foldersRoundTrip() throws {
        let directory = VMOrganizationDirectory(fileURL: fileURL)
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let clients = try directory.createFolder(named: "Clients", members: [a, b, a])
        let demo = try directory.createFolder(named: "Demo")
        let spare = try directory.createFolder(named: "Spare")
        #expect(clients.members == [a, b])

        try directory.add([c, a, b], toFolder: clients.id)
        try directory.add([b, a], toFolder: demo.id)
        try directory.move(c, before: a, inFolder: clients.id)
        try directory.remove(b, fromFolder: demo.id)
        try directory.renameFolder(demo.id, to: "Demos")
        try directory.moveFolder(spare.id, before: clients.id)

        let reread = VMOrganizationDirectory(fileURL: fileURL)
        #expect(reread.folders == directory.folders)
        #expect(reread.folders.map(\.name) == ["Spare", "Clients", "Demos"])
        #expect(reread.folder(withID: clients.id)?.members == [c, a, b])
        #expect(reread.folder(withID: demo.id)?.members == [a])

        try reread.removeFromEveryFolder([a])
        try reread.removeFolder(spare.id)
        let pruned = VMOrganizationDirectory(fileURL: fileURL)
        #expect(pruned.folders.map(\.id) == [clients.id, demo.id])
        #expect(pruned.folders.map(\.members) == [[c, b], []])
    }

    @Test("A file holding only smart groups reads with no folders, and keeps its groups as a folder is added")
    func smartGroupsOnlyFileReadsWithNoFolders() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let full = try #require(try parsed(Data(fixture(named: "Old").utf8)).mutableCopy() as? NSMutableDictionary)
        full.removeObject(forKey: "folders")
        try JSONSerialization.data(withJSONObject: full).write(to: fileURL)
        let directory = VMOrganizationDirectory(fileURL: fileURL)
        #expect(directory.readFailure == nil)
        #expect(directory.smartGroups.map(\.name) == ["Old"])
        #expect(directory.folders.isEmpty)

        let member = try #require(UUID(uuidString: "6F1D7E2C-0000-4000-8000-0000000000AA"))
        let folder = try directory.createFolder(named: "Clients", members: [member])

        full["folders"] = [["id": folder.id.uuidString, "members": [member.uuidString], "name": "Clients"]]
        #expect(try parsed(Data(contentsOf: fileURL)) == full)
    }

    @Test("A name has to be non-empty and unique ignoring case")
    func namesAreValidated() throws {
        let directory = VMOrganizationDirectory(fileURL: nil)
        let lab = try directory.createSmartGroup(named: "Lab", filter: VMLibraryFilter())
        let bench = try directory.createSmartGroup(named: "Bench", filter: VMLibraryFilter())
        #expect(throws: VMOrganizationDirectory.ChangeError.nameRequired(.smartGroup)) {
            try directory.createSmartGroup(named: "  ", filter: VMLibraryFilter())
        }
        #expect(throws: VMOrganizationDirectory.ChangeError.nameTaken("Lab", .smartGroup)) {
            try directory.createSmartGroup(named: "LAB", filter: VMLibraryFilter())
        }
        #expect(throws: VMOrganizationDirectory.ChangeError.nameTaken("Lab", .smartGroup)) {
            try directory.renameSmartGroup(bench.id, to: "lab")
        }
        // Its own name, recased, is a rename.
        try directory.renameSmartGroup(lab.id, to: "LAB")
        #expect(directory.smartGroups.map(\.name) == ["LAB", "Bench"])
        // An identifier already names a group wherever a name does.
        let identifier = UUID().uuidString
        #expect(throws: VMOrganizationDirectory.ChangeError.nameIsIdentifier(identifier, .smartGroup)) {
            try directory.createSmartGroup(named: identifier, filter: VMLibraryFilter())
        }
        #expect(throws: VMOrganizationDirectory.ChangeError.nameIsIdentifier(identifier, .smartGroup)) {
            try directory.renameSmartGroup(bench.id, to: identifier)
        }
    }

    @Test("A name or an identifier selects a group, the name ignoring case")
    func namesSelectGroups() throws {
        let directory = VMOrganizationDirectory(fileURL: nil)
        let lab = try directory.createSmartGroup(named: "Linux Lab", filter: VMLibraryFilter())

        #expect(directory.smartGroup(named: "linux lab") == lab)
        #expect(directory.smartGroup(named: " LINUX LAB ") == lab)
        #expect(directory.smartGroup(named: lab.id.uuidString) == lab)
        #expect(directory.smartGroup(named: "Linux") == nil)
        #expect(directory.smartGroup(named: UUID().uuidString) == nil)
    }

    @Test("A suggested name steps past the names already taken")
    func unusedName() throws {
        let directory = VMOrganizationDirectory(fileURL: nil)
        #expect(directory.unusedName(from: "Linux", for: .smartGroup) == "Linux")
        try directory.createSmartGroup(named: "Linux", filter: VMLibraryFilter())
        try directory.createSmartGroup(named: "linux 2", filter: VMLibraryFilter())
        #expect(directory.unusedName(from: "Linux", for: .smartGroup) == "Linux 3")
    }

    @Test("A file that cannot be read is never overwritten")
    func anUnreadableFileRefusesChanges() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        let directory = VMOrganizationDirectory(fileURL: fileURL)

        #expect(directory.readFailure != nil)
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
        #expect(second.smartGroups.map(\.name) == ["Lab", "Bench"])
        // A name the other copy took is refused, though this one never saw it.
        #expect(throws: VMOrganizationDirectory.ChangeError.nameTaken("Bench", .smartGroup)) {
            try first.createSmartGroup(named: "bench", filter: VMLibraryFilter())
        }
        try second.setFilter(VMLibraryFilter(states: [.running]), ofSmartGroup: lab.id)

        first.reload()
        #expect(first.smartGroups.map(\.name) == ["Lab", "Bench"])
        #expect(first.smartGroup(withID: lab.id)?.filter == VMLibraryFilter(states: [.running]))
    }

    @Test("The library takes in another copy's edits when it refreshes from other copies")
    func libraryRefreshReadsOtherCopiesEdits() throws {
        let mine = VMOrganizationDirectory(fileURL: fileURL)
        let library = makeWiredLibrary(organization: mine)
        let theirs = VMOrganizationDirectory(fileURL: fileURL)
        let group = try theirs.createSmartGroup(named: "Theirs", filter: VMLibraryFilter())
        #expect(library.smartGroups.isEmpty)

        library.refreshFromOtherCopies()

        #expect(library.smartGroups.map(\.id) == [group.id])
        #expect(library.sidebarLayout.sections.map(\.id) == [.smartGroup(group.id), .library])
    }
}
