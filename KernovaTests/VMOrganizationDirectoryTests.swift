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
        try directory.moveSection(.smartGroup(everything.id), before: .smartGroup(running.id))

        let reread = VMOrganizationDirectory(fileURL: fileURL)
        #expect(reread.smartGroups?.map(\.name) == ["Everything", "Running", "Apple"])
        #expect(reread.state == directory.state)
        #expect(reread.smartGroup(withID: macs.id)?.filter == VMLibraryFilter(guestOSes: [.macOS], ephemeralOnly: true))
        #expect(reread.smartGroup(withID: everything.id)?.filter.isActive == false)

        try reread.moveSection(.smartGroup(everything.id), before: nil)
        try reread.removeSmartGroup(running.id)
        #expect(VMOrganizationDirectory(fileURL: fileURL).smartGroups?.map(\.id) == [macs.id, everything.id])
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
            directory.sections?.map(\.id) == [
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
        try directory.moveSection(.folder(spare.id), before: .folder(clients.id))

        let reread = VMOrganizationDirectory(fileURL: fileURL)
        #expect(reread.folders == directory.folders)
        #expect(reread.folders?.map(\.name) == ["Spare", "Clients", "Demos"])
        #expect(reread.folder(withID: clients.id)?.members == [c, a, b])
        #expect(reread.folder(withID: demo.id)?.members == [a])

        try reread.removeFromEveryFolder([a])
        try reread.removeFolder(spare.id)
        let pruned = VMOrganizationDirectory(fileURL: fileURL)
        #expect(pruned.folders?.map(\.id) == [clients.id, demo.id])
        #expect(pruned.folders?.map(\.members) == [[c, b], []])
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

    @Test(
        "A file with no section order lists its smart groups, then its folders, each in its list's order, then the library"
    )
    func fileWithNoSectionOrderListsSmartGroupsFirst() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let full = try #require(try parsed(Data(fixture(named: "Old").utf8)).mutableCopy() as? NSMutableDictionary)
        full.removeObject(forKey: "sectionOrder")
        let second = try #require(UUID(uuidString: "6F1D7E2C-0000-4000-8000-000000000003"))
        let groups = try #require(full["smartGroups"] as? [[String: Any]])
        var copy = try #require(groups.first)
        copy["id"] = second.uuidString
        copy["name"] = "Second"
        full["smartGroups"] = groups + [copy]
        try JSONSerialization.data(withJSONObject: full).write(to: fileURL)

        let directory = VMOrganizationDirectory(fileURL: fileURL)

        #expect(directory.state.unreadable == nil)
        #expect(
            directory.sections?.map(\.id) == [
                .smartGroup(try #require(UUID(uuidString: "6F1D7E2C-0000-4000-8000-000000000001"))),
                .smartGroup(second),
                .folder(try #require(UUID(uuidString: "6F1D7E2C-0000-4000-8000-000000000002"))),
                .library,
            ])
    }

    @Test("A section the order does not name follows the ones it does; an identifier no section carries is ignored")
    func partialSectionOrder() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let full = try #require(try parsed(Data(fixture(named: "Old").utf8)).mutableCopy() as? NSMutableDictionary)
        full["sectionOrder"] = ["folder:\(UUID().uuidString)", "folder:6F1D7E2C-0000-4000-8000-000000000002"]
        try JSONSerialization.data(withJSONObject: full).write(to: fileURL)
        let group = try #require(UUID(uuidString: "6F1D7E2C-0000-4000-8000-000000000001"))
        let folder = try #require(UUID(uuidString: "6F1D7E2C-0000-4000-8000-000000000002"))

        let directory = VMOrganizationDirectory(fileURL: fileURL)
        #expect(directory.sections?.map(\.id) == [.folder(folder), .smartGroup(group), .library])

        // The next write states every section, and only those.
        let made = try directory.createFolder(named: "Made")
        #expect(
            try parsed(Data(contentsOf: fileURL))["sectionOrder"] as? [String] == [
                "folder:\(folder.uuidString)", "smartGroup:\(group.uuidString)", "virtualMachines",
                "folder:\(made.id.uuidString)",
            ])
    }

    @Test("Smart groups, folders and the library share one order, kept across a reread")
    func interleavedOrderRoundTrip() throws {
        let directory = VMOrganizationDirectory(fileURL: fileURL)
        #expect(directory.sections == [.library])
        let macs = try directory.createSmartGroup(named: "Macs", filter: VMLibraryFilter(guestOSes: [.macOS]))
        let clients = try directory.createFolder(named: "Clients")
        let running = try directory.createSmartGroup(named: "Running", filter: VMLibraryFilter(states: [.running]))
        // Each new section goes after every other, the library included.
        #expect(
            directory.sections?.map(\.id) == [
                .library, .smartGroup(macs.id), .folder(clients.id), .smartGroup(running.id),
            ])

        try directory.moveSection(.library, before: nil)
        try directory.moveSection(.folder(clients.id), before: .smartGroup(macs.id))
        try directory.moveSection(.smartGroup(running.id), before: .smartGroup(macs.id))

        let reread = VMOrganizationDirectory(fileURL: fileURL)
        #expect(reread.sections == directory.sections)
        let order: [SidebarSectionID] = [.folder(clients.id), .smartGroup(running.id), .smartGroup(macs.id), .library]
        #expect(reread.sections?.map(\.id) == order)
        #expect(reread.smartGroups?.map(\.id) == [running.id, macs.id])
        #expect(reread.folders?.map(\.id) == [clients.id])
        #expect(try parsed(Data(contentsOf: fileURL))["sectionOrder"] as? [String] == order.map(\.rawValue))
    }

    @Test("Deleting a smart group or a folder leaves the order naming the rest, and a new section goes last")
    func deleteKeepsTheOrderConsistent() throws {
        let directory = VMOrganizationDirectory(fileURL: fileURL)
        let macs = try directory.createSmartGroup(named: "Macs", filter: VMLibraryFilter())
        let clients = try directory.createFolder(named: "Clients")
        let demo = try directory.createFolder(named: "Demo")
        try directory.moveSection(.library, before: nil)

        try directory.removeSmartGroup(macs.id)
        try directory.removeFolder(demo.id)

        let pruned = VMOrganizationDirectory(fileURL: fileURL)
        #expect(pruned.sections?.map(\.id) == [.folder(clients.id), .library])
        #expect(
            try parsed(Data(contentsOf: fileURL))["sectionOrder"] as? [String] == [
                SidebarSectionID.folder(clients.id).rawValue, SidebarSectionID.library.rawValue,
            ])
        let made = try pruned.createSmartGroup(named: "Made", filter: VMLibraryFilter())
        #expect(pruned.sections?.map(\.id) == [.folder(clients.id), .library, .smartGroup(made.id)])
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
        #expect(directory.smartGroups?.map(\.name) == ["LAB", "Bench"])
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

        #expect(directory.state.listed?.smartGroup(named: "linux lab") == lab)
        #expect(directory.state.listed?.smartGroup(named: " LINUX LAB ") == lab)
        #expect(directory.state.listed?.smartGroup(named: lab.id.uuidString) == lab)
        #expect(directory.state.listed?.smartGroup(named: "Linux") == nil)
        #expect(directory.state.listed?.smartGroup(named: UUID().uuidString) == nil)
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
        #expect(throws: VMOrganizationDirectory.ChangeError.nameTaken("Bench", .smartGroup)) {
            try first.createSmartGroup(named: "bench", filter: VMLibraryFilter())
        }
        try second.setFilter(VMLibraryFilter(states: [.running]), ofSmartGroup: lab.id)

        first.reload()
        #expect(first.smartGroups?.map(\.name) == ["Lab", "Bench"])
        #expect(first.smartGroup(withID: lab.id)?.filter == VMLibraryFilter(states: [.running]))
    }

    @Test("The library takes in another copy's edits when it refreshes from other copies")
    func libraryRefreshReadsOtherCopiesEdits() throws {
        let mine = VMOrganizationDirectory(fileURL: fileURL)
        let library = makeWiredLibrary(organization: mine)
        let theirs = VMOrganizationDirectory(fileURL: fileURL)
        let group = try theirs.createSmartGroup(named: "Theirs", filter: VMLibraryFilter())
        #expect(library.smartGroups == [])

        library.refreshFromOtherCopies()

        #expect(library.smartGroups?.map(\.id) == [group.id])
        #expect(library.sidebarLayout.sections.map(\.id) == [.library, .smartGroup(group.id)])
    }

    @Test("A change naming a smart group, folder or tag the file no longer holds is refused, and changes nothing")
    func changeToAMissingElementIsRefused() throws {
        let directory = VMOrganizationDirectory(fileURL: fileURL)
        let group = try directory.createSmartGroup(named: "Macs", filter: VMLibraryFilter(guestOSes: [.macOS]))
        let folder = try directory.createFolder(named: "Lab")
        let tag = try directory.createTag(named: "Work", color: .blue)
        let kept = try directory.createFolder(named: "Kept")
        try directory.removeSmartGroup(group.id)
        try directory.removeFolder(folder.id)
        try directory.removeTag(tag.id)
        let before = directory.state
        let entry = UUID()

        #expect(throws: VMOrganizationDirectory.ChangeError.missing(.smartGroup)) {
            try directory.renameSmartGroup(group.id, to: "Apple")
        }
        #expect(throws: VMOrganizationDirectory.ChangeError.missing(.smartGroup)) {
            try directory.setFilter(VMLibraryFilter(), ofSmartGroup: group.id)
        }
        #expect(throws: VMOrganizationDirectory.ChangeError.missing(.folder)) {
            try directory.renameFolder(folder.id, to: "Bench")
        }
        #expect(throws: VMOrganizationDirectory.ChangeError.missing(.folder)) {
            try directory.add([entry], toFolder: folder.id)
        }
        #expect(throws: VMOrganizationDirectory.ChangeError.missing(.folder)) {
            try directory.remove(entry, fromFolder: folder.id)
        }
        #expect(throws: VMOrganizationDirectory.ChangeError.missing(.folder)) {
            try directory.move(entry, before: nil, inFolder: folder.id)
        }
        #expect(throws: VMOrganizationDirectory.ChangeError.missing(.tag)) {
            try directory.renameTag(tag.id, to: "Office")
        }
        #expect(throws: VMOrganizationDirectory.ChangeError.missing(.tag)) {
            try directory.setColor(.red, ofTag: tag.id)
        }
        #expect(directory.state == before)
        #expect(VMOrganizationDirectory(fileURL: fileURL).state == before)
        #expect(directory.folders?.map(\.id) == [kept.id])
    }

    @Test("Renaming a deleted smart group, folder or tag reports it missing, whatever the name")
    func renameOfAMissingElementReportsItMissing() throws {
        let directory = VMOrganizationDirectory(fileURL: fileURL)
        let group = try directory.createSmartGroup(named: "Macs", filter: VMLibraryFilter(guestOSes: [.macOS]))
        let folder = try directory.createFolder(named: "Lab")
        let tag = try directory.createTag(named: "Work", color: .blue)
        try directory.createSmartGroup(named: "Linux", filter: VMLibraryFilter(guestOSes: [.linux]))
        try directory.createFolder(named: "Kept")
        try directory.createTag(named: "Home", color: .red)
        try directory.removeSmartGroup(group.id)
        try directory.removeFolder(folder.id)
        try directory.removeTag(tag.id)

        for name in ["", " ", UUID().uuidString] {
            #expect(throws: VMOrganizationDirectory.ChangeError.missing(.smartGroup)) {
                try directory.renameSmartGroup(group.id, to: name)
            }
            #expect(throws: VMOrganizationDirectory.ChangeError.missing(.folder)) {
                try directory.renameFolder(folder.id, to: name)
            }
            #expect(throws: VMOrganizationDirectory.ChangeError.missing(.tag)) {
                try directory.renameTag(tag.id, to: name)
            }
        }
        #expect(throws: VMOrganizationDirectory.ChangeError.missing(.smartGroup)) {
            try directory.renameSmartGroup(group.id, to: "Linux")
        }
        #expect(throws: VMOrganizationDirectory.ChangeError.missing(.folder)) {
            try directory.renameFolder(folder.id, to: "Kept")
        }
        #expect(throws: VMOrganizationDirectory.ChangeError.missing(.tag)) {
            try directory.renameTag(tag.id, to: "Home")
        }
    }
}
