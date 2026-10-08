import Cocoa
import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// The library's config files Kernova can't read: kept in sight as rows no
/// verb addresses, reported once, listed by the check, and repaired by Use
/// Defaults where every problem has a default.
@Suite("VMLibrary config check", .serialized, .caseScoped)
@MainActor
struct VMLibraryConfigCheckTests {
    private let preferences = makeTestPreferences()
    private let scratch = TestScratchDirectory(prefix: "VMLibraryConfigCheckTests")
    /// Records what Use Defaults moves to the Trash, so nothing lands in the
    /// user's own.
    private let fileSystem = MockFileSystem()

    /// A value no field of any config type takes.
    private static let unrecognized = "plan9-mode"

    private struct Harness {
        let library: VMLibrary
        let core: VMCommandCore
        let storage: MockVMStorageService
        /// How many times the library asked for the check to come up.
        let checkRequests: Counter
    }

    @MainActor
    private final class Counter {
        var count = 0
    }

    private func makeHarness(
        networks: VMNetworkDirectory = VMNetworkDirectory(fileURL: nil),
        organization: VMOrganizationDirectory = VMOrganizationDirectory(fileURL: nil)
    ) -> Harness {
        let storage = MockVMStorageService()
        let lifecycle = makeTestLifecycle(
            virtualization: MockVirtualizationService(), fileSystem: fileSystem)
        let library = makeWiredLibrary(
            storage: storage, machineFiles: MockVMBundleMachineFiles(files: storage.files),
            lifecycle: lifecycle, fileSystem: fileSystem, preferences: preferences,
            networks: networks, organization: organization)
        let core = VMCommandCore(
            library: library, lifecycle: lifecycle, storageService: storage,
            diskImageService: MockDiskImageService(), fileSystem: fileSystem,
            preferences: preferences)
        let counter = Counter()
        library.onUnreadableFilesFound = { counter.count += 1 }
        return Harness(library: library, core: core, storage: storage, checkRequests: counter)
    }

    /// A bundle whose `config.json` is `name`'s configuration with `edit`
    /// applied to its JSON; `edit` may make it unreadable.
    @discardableResult
    private func addBundle(
        _ name: String, to storage: MockVMStorageService,
        edit: (inout [String: Any]) -> Void = { _ in }
    ) throws -> (url: URL, bytes: Data) {
        let config = VMConfiguration(name: name, guestOS: .linux, bootMode: .efi)
        let url = try storage.bundleURL(for: config)
        let bytes = try Self.json(of: config, edit: edit)
        storage.files.setData(bytes, atRelativePath: VMBundleLayout.configRelativePath, in: url)
        return (url, bytes)
    }

    private static func json(
        of config: VMConfiguration, edit: (inout [String: Any]) -> Void
    ) throws -> Data {
        let data = try VMConfiguration.makeJSONEncoder().encode(config)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func configBytes(at url: URL, in storage: MockVMStorageService) -> Data? {
        storage.files.data(atRelativePath: VMBundleLayout.configRelativePath, in: url)
    }

    // MARK: - The unreadable row

    @Test("A bundle whose config can't be read stays in the library as a row no verb can address")
    func anUnreadableBundleIsARowWithNoOperations() async throws {
        let harness = makeHarness()
        try addBundle("Readable", to: harness.storage)
        let (url, _) = try addBundle("Dev", to: harness.storage) {
            $0["networkMode"] = Self.unrecognized
        }

        await harness.library.loadVMs()

        let row = try #require(harness.library.entries.compactMap(\.unreadable).first)
        #expect(row.name == "Dev")
        #expect(row.bundleURL == url)
        #expect(row.file.location == .bundle(url, .configuration))
        #expect(row.file.isRepairable)
        #expect(row.toolTip.contains("$.networkMode: \u{201C}\(Self.unrecognized)\u{201D}"))
        #expect(row.toolTip.hasSuffix("Choose File > Check Config Files\u{2026} to review it."))
        // No VM is built from it, so nothing that takes a VM can reach it.
        #expect(harness.library.instances.map(\.name) == ["Readable"])
        #expect(harness.library.entries.compactMap(\.addressable).map(\.name) == ["Readable"])
        #expect(harness.core.list(.all).map(\.name) == ["Readable"])
        #expect(throws: CommandError.notFound(.id(row.id))) { try harness.core.resolve(.id(row.id)) }
        #expect(throws: CommandError.notFound(.name("Dev"))) { try harness.core.info(.name("Dev")) }
    }

    @Test("A bundle whose config has no name is named by its folder")
    func anUnnamedBundleIsNamedByItsFolder() async throws {
        let harness = makeHarness()
        let (url, _) = try addBundle("Dev", to: harness.storage) { $0["name"] = nil }

        await harness.library.loadVMs()

        let row = try #require(harness.library.entries.compactMap(\.unreadable).first)
        #expect(row.name == url.lastPathComponent)
        #expect(!row.file.isRepairable)
    }

    // MARK: - The unreadable row among the library's groups

    /// The identifier `bytes`' configuration gives its VM.
    private static func id(in bytes: Data) throws -> UUID {
        let object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let text = try #require(object["id"] as? String)
        return try #require(UUID(uuidString: text))
    }

    @Test("An unreadable row is in no smart group or folder, and no listing or group action reaches it")
    func anUnreadableRowIsInNoGroup() async throws {
        let harness = makeHarness()
        let (_, readableBytes) = try addBundle("Readable", to: harness.storage)
        let (_, devBytes) = try addBundle("Dev", to: harness.storage) { $0["networkMode"] = Self.unrecognized }
        let readable = try Self.id(in: readableBytes)
        let dev = try Self.id(in: devBytes)
        await harness.library.loadVMs()
        let row = try #require(harness.library.entries.compactMap(\.unreadable).first)
        // A folder holding the VM by the identifier its config gives it, from
        // before the config turned unreadable, and a smart group admitting
        // every VM.
        let folder = try harness.library.organization.createFolder(named: "Lab", members: [readable, dev])
        let group = try harness.library.organization.createSmartGroup(named: "All", filter: VMLibraryFilter())

        let layout = harness.library.sidebarLayout
        func listed(in section: SidebarSectionID) -> [UUID] {
            layout.rowKeys.filter { $0.section == section }.map(\.entryID)
        }
        #expect(listed(in: .folder(folder.id)) == [readable])
        #expect(listed(in: .smartGroup(group.id)) == [readable])
        #expect(Set(listed(in: .library)) == [readable, row.id])
        // The folder keeps the identifier, so the VM is listed there again
        // once its config reads.
        #expect(harness.library.organization.folder(withID: folder.id)?.members == [readable, dev])

        for reference in [VMGroupReference(.folder, named: "Lab"), VMGroupReference(.smartGroup, named: "All")] {
            let selection = try harness.core.selection(for: VMListQuery(groups: [reference]), verb: .list)
            #expect(harness.core.list(selection).map(\.id) == [readable], "\(reference)")
            let report = try await harness.core.groupAction(.stop, on: reference)
            #expect(report.results.map(\.vm.id) == [readable], "\(reference)")
            #expect(try harness.core.concernedCounts(in: reference).values.allSatisfy { $0 <= 1 }, "\(reference)")
        }
        #expect(try harness.core.groups().map { $0.members.map(\.id) } == [[readable], [readable]])
    }

    @Test("An unreadable row sorts with no run recorded, matches a search by its name, and restores as the selection")
    func anUnreadableRowInTheSidebar() async throws {
        let harness = makeHarness()
        try addBundle("Readable", to: harness.storage)
        try addBundle("Dev", to: harness.storage) { $0["networkMode"] = Self.unrecognized }
        await harness.library.loadVMs()
        let row = try #require(harness.library.entries.first { $0.unreadable != nil })
        let library = harness.library

        #expect(row.lastRun == .unrecorded)
        #expect(VMLibrarySort.dateCreated.ordered(library.entries).last?.id == row.id)

        // Under every grouping it is listed alone under "Can't Be Read".
        for grouping in SidebarGrouping.allCases where grouping != .none {
            library.sidebarOptions = SidebarViewOptions(grouping: grouping)
            let section = try #require(library.sidebarLayout.sections.first { $0.id == .library })
            guard case .groups(let groups) = section.content else {
                Issue.record("\(grouping) lists no groups")
                continue
            }
            let holding = groups.groups.filter { group in group.rows.entries.contains { $0.id == row.id } }
            #expect(holding.map(\.title) == [UnreadableVM.statusText], "\(grouping)")
            #expect(holding.first?.rows.entries.count == 1, "\(grouping)")
        }
        library.sidebarOptions = SidebarViewOptions()

        library.sidebarSearch = SidebarNameSearch(text: "de")
        #expect(library.sidebarLayout.rowKeys.map(\.entryID) == [row.id])
        library.sidebarSearch = SidebarNameSearch(text: "read")
        #expect(library.sidebarLayout.rowKeys.map(\.entryID) != [row.id])
        library.sidebarSearch = SidebarNameSearch()

        // A filter on what a config holds keeps the row listed, its way out
        // in sight.
        library.sidebarOptions = SidebarViewOptions(filter: VMLibraryFilter(guestOSes: [.macOS]))
        #expect(library.sidebarLayout.rowKeys.map(\.entryID) == [row.id])
        library.sidebarOptions = SidebarViewOptions()

        // The row's identifier is fixed by its bundle, so a remembered
        // selection of it is restored as the library's selection is.
        library.selection = .library(row.id)
        #expect(preferences.sidebarSelection == .library(row.id))
        library.selection = nil
        preferences.sidebarSelection = .library(row.id)
        library.restoreSelection()
        #expect(library.selection == .library(row.id))
    }

    @Test("A listing naming a tag, a group or a network refuses while the file listing them can't be read")
    func listingsRefuseUnreadableLists() async throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let organizationURL = scratch.url.appendingPathComponent("Organization.json")
        let networksURL = scratch.url.appendingPathComponent("Networks.json")
        try Data("not json".utf8).write(to: organizationURL)
        try Data("not json".utf8).write(to: networksURL)
        let harness = makeHarness(
            networks: VMNetworkDirectory(fileURL: networksURL),
            organization: VMOrganizationDirectory(fileURL: organizationURL))
        try addBundle("Readable", to: harness.storage)
        await harness.library.loadVMs()

        let organizationRefusal = CommandError.operationFailed(
            verb: .list, message: VMOrganizationDirectory.unreadableMessage)
        #expect(throws: organizationRefusal) {
            try harness.core.selection(for: VMListQuery(tags: ["Work"]), verb: .list)
        }
        #expect(throws: organizationRefusal) {
            try harness.core.selection(for: VMListQuery(groups: [VMGroupReference(.folder, named: "Lab")]), verb: .list)
        }
        #expect(throws: CommandError.operationFailed(verb: .groups, message: VMOrganizationDirectory.unreadableMessage))
        {
            try harness.core.groups()
        }
        #expect(throws: CommandError.operationFailed(verb: .list, message: VMNetworkDirectory.unreadableMessage)) {
            try harness.core.selection(for: VMListQuery(networks: ["Lab"]), verb: .list)
        }
        // A mode needs no list, and an unfiltered listing none either.
        #expect(
            try harness.core.selection(for: VMListQuery(networks: ["nat"]), verb: .list).filter.networks.count == 1)
        #expect(harness.core.list(.all).map(\.name) == ["Readable"])
    }

    // MARK: - Reporting

    @Test("The load asks for the check once, and a reconcile only for a newly unreadable file")
    func theCheckComesUpOnlyForNewProblems() async throws {
        let networksURL = scratch.url.appendingPathComponent("Networks.json")
        let harness = makeHarness(networks: VMNetworkDirectory(fileURL: networksURL))
        try addBundle("Dev", to: harness.storage) { $0["networkMode"] = Self.unrecognized }

        await harness.library.loadVMs()
        #expect(harness.checkRequests.count == 1)

        harness.library.reconcileWithDisk()
        #expect(harness.checkRequests.count == 1)

        try addBundle("Second", to: harness.storage) { $0["guestOS"] = Self.unrecognized }
        harness.library.reconcileWithDisk()
        #expect(harness.checkRequests.count == 2)
        harness.library.reconcileWithDisk()
        #expect(harness.checkRequests.count == 2)

        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: networksURL)
        harness.library.refreshFromOtherCopies()
        #expect(harness.checkRequests.count == 3)
        harness.library.refreshFromOtherCopies()
        #expect(harness.checkRequests.count == 3)
    }

    // MARK: - The check

    @Test("The check reads the config of every snapshot a manifest lists")
    func theCheckReadsSnapshotConfigs() async throws {
        let harness = makeHarness()
        let (url, _) = try addBundle("Dev", to: harness.storage)
        let snapshotID = UUID()
        let manifest = """
            {"snapshots": [{"id": "\(snapshotID.uuidString)", "name": "Before update",
              "createdAt": "2026-01-01T00:00:00Z", "notes": "", "kind": "cold"}]}
            """
        harness.storage.files.setData(
            Data(manifest.utf8), atRelativePath: VMBundleLayout.snapshotManifestRelativePath, in: url)
        let snapshotConfig = try Self.json(
            of: VMConfiguration(name: "Dev", guestOS: .linux, bootMode: .efi)
        ) { $0["displayHiDPI"] = Self.unrecognized }
        let snapshotPath = VMBundleLayout.snapshotConfigRelativePath(id: snapshotID)
        harness.storage.files.setData(snapshotConfig, atRelativePath: snapshotPath, in: url)
        // One bundle read reads each snapshot's config once, for both its
        // network and whether it reads.
        let readsBefore = harness.storage.files.readCount(of: snapshotPath)
        let read = try VMBundleFiles(url: url, access: harness.storage.files).read()
        #expect(harness.storage.files.readCount(of: snapshotPath) - readsBefore == 1)
        #expect(read.unreadableFiles.map(\.location) == [.bundle(url, .snapshotConfiguration(snapshotID))])
        #expect(read.snapshotManifest.snapshot(id: snapshotID)?.network != nil)
        await harness.library.loadVMs()
        #expect(harness.library.instances.map(\.name) == ["Dev"])

        let files = try await harness.library.checkConfigFiles()

        let file = try #require(files.first)
        #expect(files.count == 1)
        #expect(file.location == .bundle(url, .snapshotConfiguration(snapshotID)))
        #expect(file.owner == .snapshot(vm: "Dev", snapshot: "Before update"))
        #expect(file.owner.title == "Dev \u{2014} snapshot \u{201C}Before update\u{201D}")
        #expect(file.isRepairable)

        let failures = await harness.library.useDefaults(in: files)

        #expect(failures.isEmpty)
        #expect(try await harness.library.checkConfigFiles().isEmpty)
        #expect(
            fileSystem.trashedURLs.map(\.lastPathComponent) == [
                "Dev \u{2014} snapshot \u{201C}Before update\u{201D} \u{2014} config.json"
            ])
    }

    @Test("A snapshot config's unrecognized network value is listed with no repair: it is what the snapshot had")
    func aSnapshotsNetworkIsNotRepaired() async throws {
        let harness = makeHarness()
        let (url, _) = try addBundle("Dev", to: harness.storage)
        let snapshotID = UUID()
        let manifest = """
            {"snapshots": [{"id": "\(snapshotID.uuidString)", "name": "Before update",
              "createdAt": "2026-01-01T00:00:00Z", "notes": "", "kind": "cold"}]}
            """
        harness.storage.files.setData(
            Data(manifest.utf8), atRelativePath: VMBundleLayout.snapshotManifestRelativePath, in: url)
        let snapshotConfig = try Self.json(
            of: VMConfiguration(name: "Dev", guestOS: .linux, bootMode: .efi)
        ) {
            $0["networkMode"] = Self.unrecognized
            $0["displayHiDPI"] = Self.unrecognized
        }
        harness.storage.files.setData(
            snapshotConfig, atRelativePath: VMBundleLayout.snapshotConfigRelativePath(id: snapshotID), in: url)
        await harness.library.loadVMs()

        let file = try #require(try await harness.library.checkConfigFiles().first)

        #expect(file.problems.map(\.path?.description) == ["$.displayHiDPI", "$.networkMode"])
        #expect(file.problems.first { $0.path?.description == "$.networkMode" }?.repair == nil)
        #expect(file.problems.first { $0.path?.description == "$.displayHiDPI" }?.repair != nil)
        #expect(!file.isRepairable)
    }

    // MARK: - Use Defaults

    @Test("Use Defaults rewrites only the repairable files, trashing each original, and the VM loads")
    func useDefaultsRewritesOnlyRepairableFiles() async throws {
        let harness = makeHarness()
        let (repairableURL, repairableBytes) = try addBundle("Dev", to: harness.storage) {
            $0["networkMode"] = Self.unrecognized
        }
        let (unrepairableURL, unrepairableBytes) = try addBundle("Nameless", to: harness.storage) {
            $0["name"] = nil
            $0["displayHiDPI"] = Self.unrecognized
        }
        await harness.library.loadVMs()
        let repairableRow = try #require(
            harness.library.entries.compactMap(\.unreadable).first { $0.bundleURL == repairableURL })
        harness.library.selectRevealing(repairableRow.id)

        let files = try await harness.library.checkConfigFiles()
        #expect(
            Set(files.map(\.url)) == [
                repairableURL.appendingPathComponent("config.json"),
                unrepairableURL.appendingPathComponent("config.json"),
            ])
        #expect(files.filter(\.isRepairable).map(\.url) == [repairableURL.appendingPathComponent("config.json")])

        let failures = await harness.library.useDefaults(in: files)

        #expect(failures.isEmpty)
        // The repaired bundle is a VM again, holding the default, and keeps the selection.
        let repaired = try #require(harness.library.instances.first { $0.name == "Dev" })
        #expect(
            repaired.configuration.networkMode
                == VMConfiguration(name: "", guestOS: .linux, bootMode: .efi).networkMode)
        #expect(harness.library.selectedID == repaired.id)
        #expect(configBytes(at: repairableURL, in: harness.storage) != repairableBytes)
        #expect(fileSystem.trashedURLs.map(\.lastPathComponent) == ["Dev \u{2014} config.json"])
        // The unrepairable one is untouched, byte for byte, and still a row.
        #expect(configBytes(at: unrepairableURL, in: harness.storage) == unrepairableBytes)
        #expect(
            harness.library.entries.compactMap(\.unreadable).map(\.bundleURL) == [unrepairableURL])
        #expect(
            try await harness.library.checkConfigFiles().map(\.url) == [
                unrepairableURL.appendingPathComponent("config.json")
            ])
    }

    @Test("Use Defaults leaves a file another copy of Kernova holds, and says so")
    func useDefaultsLeavesAHeldBundle() async throws {
        let harness = makeHarness()
        let (url, bytes) = try addBundle("Dev", to: harness.storage) {
            $0["networkMode"] = Self.unrecognized
        }
        harness.storage.files.holdElsewhere(url)
        await harness.library.loadVMs()

        let failures = await harness.library.useDefaults(
            in: try await harness.library.checkConfigFiles())

        #expect(failures.map(\.reason) == [ConfigFileRepairRefusal.inUse.localizedDescription])
        #expect(configBytes(at: url, in: harness.storage) == bytes)
        #expect(fileSystem.trashedURLs.isEmpty)
    }

    @Test("Use Defaults refuses a file that changed since the check, and leaves it as it now is")
    func useDefaultsRefusesChangedBytes() async throws {
        let harness = makeHarness()
        let (url, _) = try addBundle("Dev", to: harness.storage) { $0["networkMode"] = Self.unrecognized }
        await harness.library.loadVMs()
        let files = try await harness.library.checkConfigFiles()

        // Another writer changes the file after the user reviewed the check.
        let changed = try Self.json(of: VMConfiguration(name: "Dev", guestOS: .linux, bootMode: .efi)) {
            $0["networkMode"] = "another-unrecognized-mode"
        }
        harness.storage.files.setData(changed, atRelativePath: VMBundleLayout.configRelativePath, in: url)

        let failures = await harness.library.useDefaults(in: files)

        #expect(failures.map(\.reason) == [ConfigFileRepairRefusal.changedSinceCheck.localizedDescription])
        #expect(configBytes(at: url, in: harness.storage) == changed)
        #expect(fileSystem.trashedURLs.isEmpty)
    }

    @Test("Use Defaults takes a file now gone that reads as its default as already readable")
    func useDefaultsTakesAGoneDefaultedFileAsReadable() async throws {
        let harness = makeHarness()
        let (url, _) = try addBundle("Dev", to: harness.storage)
        harness.storage.files.setData(
            Data("not json".utf8), atRelativePath: VMBundleLayout.hostStateRelativePath, in: url)
        await harness.library.loadVMs()
        let files = try await harness.library.checkConfigFiles()
        #expect(files.map(\.location) == [.bundle(url, .hostState)])
        let checked = try #require(files.first)

        harness.storage.files.setData(nil, atRelativePath: VMBundleLayout.hostStateRelativePath, in: url)

        let repair = try VMBundleFiles(url: url, access: harness.storage.bundleFiles)
            .repair(.hostState, as: checked, trashingOriginalWith: fileSystem)
        #expect(repair == .alreadyReadable)
        #expect(fileSystem.trashedURLs.isEmpty)
    }

    // MARK: - Move to Trash

    @Test("Move to Trash refuses a bundle whose run lock another holder has, and moves it once free")
    func moveToTrashTakesTheRunLock() async throws {
        let harness = makeHarness()
        let (url, _) = try addBundle("Dev", to: harness.storage) { $0["networkMode"] = Self.unrecognized }
        await harness.library.loadVMs()
        let row = try #require(harness.library.entries.compactMap(\.unreadable).first)
        harness.storage.files.holdElsewhere(url)

        await #expect(throws: ConfigFileRepairRefusal.inUse) { try await harness.library.moveToTrash(row) }
        #expect(harness.storage.deleteVMBundleCallCount == 0)
        #expect(configBytes(at: url, in: harness.storage) != nil)

        harness.storage.files.releaseElsewhere(url)
        try await harness.library.moveToTrash(row)
        #expect(harness.storage.deleteVMBundleCallCount == 1)
        #expect(harness.library.entries.compactMap(\.unreadable).isEmpty)
    }

    @Test("Move to Trash refuses a bundle repaired since its row was read, which reads as a VM again")
    func moveToTrashRefusesARepairedBundle() async throws {
        let harness = makeHarness()
        let (url, _) = try addBundle("Dev", to: harness.storage) { $0["networkMode"] = Self.unrecognized }
        await harness.library.loadVMs()
        let row = try #require(harness.library.entries.compactMap(\.unreadable).first)

        // Another copy repairs the file after this one's row was read.
        let repaired = try Self.json(of: VMConfiguration(name: "Dev", guestOS: .linux, bootMode: .efi)) { _ in }
        harness.storage.files.setData(repaired, atRelativePath: VMBundleLayout.configRelativePath, in: url)

        await #expect(throws: ConfigFileRepairRefusal.readsNow) { try await harness.library.moveToTrash(row) }
        #expect(harness.storage.deleteVMBundleCallCount == 0)
        #expect(configBytes(at: url, in: harness.storage) == repaired)
    }

    @Test("Move to Trash refuses a bundle whose file changed since its row was read, though still unreadable")
    func moveToTrashRefusesChangedBytes() async throws {
        let harness = makeHarness()
        let (url, _) = try addBundle("Dev", to: harness.storage) { $0["networkMode"] = Self.unrecognized }
        await harness.library.loadVMs()
        let row = try #require(harness.library.entries.compactMap(\.unreadable).first)

        let changed = try Self.json(of: VMConfiguration(name: "Dev", guestOS: .linux, bootMode: .efi)) {
            $0["networkMode"] = "another-unrecognized-mode"
        }
        harness.storage.files.setData(changed, atRelativePath: VMBundleLayout.configRelativePath, in: url)

        await #expect(throws: ConfigFileRepairRefusal.changedSinceCheck) {
            try await harness.library.moveToTrash(row)
        }
        #expect(harness.storage.deleteVMBundleCallCount == 0)
    }

    // MARK: - Reporting the bundle's other files

    @Test("A load asks for the check once for a snapshot config it can't read, the VM loading as it is")
    func aLoadReportsAnUnreadableSnapshotConfigOnce() async throws {
        let harness = makeHarness()
        let (url, _) = try addBundle("Dev", to: harness.storage)
        let snapshotID = UUID()
        let manifest = """
            {"snapshots": [{"id": "\(snapshotID.uuidString)", "name": "Before update",
              "createdAt": "2026-01-01T00:00:00Z", "notes": "", "kind": "cold"}]}
            """
        harness.storage.files.setData(
            Data(manifest.utf8), atRelativePath: VMBundleLayout.snapshotManifestRelativePath, in: url)
        harness.storage.files.setData(
            Data("not json".utf8), atRelativePath: VMBundleLayout.snapshotConfigRelativePath(id: snapshotID),
            in: url)

        await harness.library.loadVMs()

        #expect(harness.library.instances.map(\.name) == ["Dev"])
        #expect(harness.checkRequests.count == 1)
        harness.library.reconcileWithDisk()
        harness.library.refreshFromOtherCopies()
        #expect(harness.checkRequests.count == 1)
    }

    @Test("A running VM's bundle is read by no list or reconcile; its unreadable config is reported once it stops")
    func aRunningVMsUnreadableConfigIsReportedWhenItStops() async throws {
        let harness = makeHarness()
        let (url, _) = try addBundle("Dev", to: harness.storage)
        await harness.library.loadVMs()
        let instance = try #require(harness.library.instances.first)
        try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        try await waitForChange { instance.status == .running }
        #expect(harness.checkRequests.count == 0)

        harness.storage.files.setData(
            Data("not json".utf8), atRelativePath: VMBundleLayout.configRelativePath, in: url)
        let stateFiles = [
            VMBundleLayout.configRelativePath, VMBundleLayout.hostStateRelativePath,
            VMBundleLayout.snapshotManifestRelativePath, VMBundleLayout.usbPairingsRelativePath,
        ]
        let reads = { stateFiles.map { harness.storage.files.readCount(of: $0) } }
        let readsBefore = reads()
        for _ in 0..<2 {
            _ = harness.core.list(.all)
            harness.library.reconcileWithDisk()
        }
        #expect(reads() == readsBefore)
        #expect(harness.checkRequests.count == 0)
        #expect(instance.status == .running)

        try await harness.core.stop(.id(instance.id), disposition: .force, consent: .all, timeout: nil)
        try await waitForChange { instance.status == .stopped }
        #expect(harness.checkRequests.count == 1)

        for _ in 0..<2 {
            _ = harness.core.list(.all)
            harness.library.reconcileWithDisk()
        }
        #expect(harness.checkRequests.count == 1)
    }

    // MARK: - A readable VM's unreadable files

    /// A readable bundle named "Dev" listing one cold snapshot, "Snapshot",
    /// whose `config.json` holds `snapshotConfig` — Ephemeral Mode on with
    /// that snapshot as its baseline when `ephemeral`.
    private func addBundleWithSnapshot(
        to storage: MockVMStorageService, ephemeral: Bool = false,
        snapshotConfig: (inout [String: Any]) -> Void = { $0["displayHiDPI"] = Self.unrecognized }
    ) throws -> (url: URL, snapshotID: UUID) {
        let (url, _) = try addBundle("Dev", to: storage)
        let snapshotID = UUID()
        let manifest = """
            {"snapshots": [{"id": "\(snapshotID.uuidString)", "name": "Snapshot",
              "createdAt": "2026-01-01T00:00:00Z", "notes": "", "kind": "cold"}]}
            """
        storage.files.setData(
            Data(manifest.utf8), atRelativePath: VMBundleLayout.snapshotManifestRelativePath, in: url)
        storage.files.setData(
            try Self.json(
                of: VMConfiguration(name: "Dev", guestOS: .linux, bootMode: .efi), edit: snapshotConfig),
            atRelativePath: VMBundleLayout.snapshotConfigRelativePath(id: snapshotID), in: url)
        if ephemeral {
            var hostState = VMHostState()
            hostState.applyEphemeralMode(enabled: true, baseline: snapshotID)
            storage.files.setData(
                try VMConfiguration.makeJSONEncoder().encode(hostState),
                atRelativePath: VMBundleLayout.hostStateRelativePath, in: url)
        }
        return (url, snapshotID)
    }

    @Test("A readable VM with a snapshot whose settings can't be read notices it until Use Defaults repairs it")
    func aReadableVMNoticesAnUnreadableSnapshotUntilRepaired() async throws {
        let harness = makeHarness()
        let (_, snapshotID) = try addBundleWithSnapshot(to: harness.storage)
        await harness.library.loadVMs()
        let instance = try #require(harness.library.instances.first)

        #expect(instance.unreadableFiles.map(\.snapshotID) == [snapshotID])
        #expect(
            UnreadableConfigFile.notice(for: instance.unreadableFiles)
                == "Kernova can\u{2019}t read the settings of snapshot \u{201C}Snapshot\u{201D}. "
                + "Choose File > Check Config Files\u{2026} to review it.")
        #expect(
            VMOverviewSummary.note(for: .snapshots, instance: instance, resolved: VMOverviewResolved())
                == "The settings of \u{201C}Snapshot\u{201D} can\u{2019}t be read")
        // The row stays a VM's: every operation the state takes is offered.
        #expect(harness.library.entries.compactMap(\.vm).map(\.id) == [instance.id])

        let failures = await harness.library.useDefaults(in: try await harness.library.checkConfigFiles())

        #expect(failures.isEmpty)
        #expect(instance.unreadableFiles.isEmpty)
        #expect(UnreadableConfigFile.notice(for: instance.unreadableFiles) == nil)
        #expect(
            VMOverviewSummary.note(for: .snapshots, instance: instance, resolved: VMOverviewResolved())
                == nil)
    }

    @Test("A snapshot error carries its heading onto the failure it becomes; an untitled error keeps the generic one")
    func snapshotErrorsAreTitled() {
        #expect(
            CommandError.failed(verb: .revertToSnapshot, error: VMSnapshotError.snapshotConfigurationUnreadable)
                .alertTitle == "Couldn\u{2019}t Revert to the Snapshot")
        #expect(
            CommandError.failed(verb: .takeSnapshot, error: VMSnapshotError.captureSourceMissing("Disk.asif"))
                .alertTitle == "Couldn\u{2019}t Take the Snapshot")
        #expect(
            CommandError.failed(verb: .start, error: CocoaError(.fileReadUnknown)).alertTitle == "Error")
    }

    @Test("The notice names the first file and counts the rest")
    func theNoticeCountsTheRest() {
        let bundle = scratch.url.appendingPathComponent("VMs/Dev.kernova")
        let problem = ConfigProblem(path: nil, issue: .fileMissing)
        let snapshot = UnreadableConfigFile(
            location: .bundle(bundle, .snapshotConfiguration(UUID())),
            owner: .snapshot(vm: "Dev", snapshot: "Clean"), problems: [problem])
        let pairings = UnreadableConfigFile(
            location: .bundle(bundle, .usbPairings), owner: .virtualMachine("Dev"), problems: [problem])

        #expect(UnreadableConfigFile.notice(for: []) == nil)
        #expect(
            UnreadableConfigFile.notice(for: [pairings])
                == "Kernova can\u{2019}t read \u{201C}\(pairings.fileName)\u{201D}. "
                + "Choose File > Check Config Files\u{2026} to review it.")
        #expect(
            UnreadableConfigFile.notice(for: [snapshot, pairings, snapshot])
                == "Kernova can\u{2019}t read the settings of snapshot \u{201C}Clean\u{201D} and 2 more files. "
                + "Choose File > Check Config Files\u{2026} to review them.")
    }

    @Test("Starting an Ephemeral VM whose baseline can't be read is refused at every door, and starts once it reads")
    func anUnreadableEphemeralBaselineRefusesEveryStart() async throws {
        let harness = makeHarness()
        let (url, snapshotID) = try addBundleWithSnapshot(to: harness.storage, ephemeral: true) {
            $0 = ["not": "a configuration"]
        }
        await harness.library.loadVMs()
        let instance = try #require(harness.library.instances.first)
        #expect(instance.ephemeralBaselineIsUnreadable)
        let refusal = CommandError.operationFailed(
            verb: .start, title: "Couldn\u{2019}t Start \u{201C}Dev\u{201D}",
            message:
                "Kernova can\u{2019}t read the snapshot Ephemeral Mode returns this virtual machine to, "
                + "so it can\u{2019}t undo this session\u{2019}s changes. "
                + "Choose File > Check Config Files\u{2026} to review it.")
        // The offer stands, so the click is what explains the refusal.
        #expect(instance.activity.decide(.start(recovery: false), posture: .offer) == .admit)

        await #expect(throws: refusal) {
            try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        }
        let router = VMCommandEnvelopeRouter(commands: harness.core)
        let response = await router.respond(
            to: VMCommandRequest(
                verb: .start(.id(instance.id), recovery: false, consent: .none, macAddressRemedy: nil)))
        #expect(response.result == .failure(refusal.dto))
        let intents = VMIntentGateway(
            commands: harness.core, readiness: LibraryReadiness(awaitReady: {}),
            index: MockVMEntityIndex(), record: makeTestIndexRecord())
        await #expect(throws: refusal) {
            try await intents.start(instance.id, recovery: false, consent: .none, macAddressRemedy: nil)
        }
        let scripting = VMScriptingGateway(
            commands: harness.core, readiness: LibraryReadiness(awaitReady: {}), prepareToSurface: {})
        await #expect(throws: refusal) {
            try await scripting.start([.id(instance.id)], recoveryMode: false, confirmation: false)
        }
        #expect(instance.status == .stopped)

        // An outside edit that makes the baseline readable is read at the
        // start's own admission.
        harness.storage.files.setData(
            try Self.json(of: VMConfiguration(name: "Dev", guestOS: .linux, bootMode: .efi)) { _ in },
            atRelativePath: VMBundleLayout.snapshotConfigRelativePath(id: snapshotID), in: url)
        try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        try await waitForChange { instance.status == .running }
        #expect(instance.unreadableFiles.isEmpty)
    }

    /// A source whose every check and Use Defaults waits until the test ends
    /// it.
    @MainActor
    @Observable
    fileprivate final class GatedConfigCheckSource: ConfigCheckSource {
        private(set) var checks: [CheckedContinuation<[UnreadableConfigFile], any Error>] = []
        private(set) var repairs: [CheckedContinuation<[VMLibrary.ConfigFileRepairFailure], Never>] = []

        func checkConfigFiles() async throws -> [UnreadableConfigFile] {
            try await withCheckedThrowingContinuation { checks.append($0) }
        }

        func useDefaults(in files: [UnreadableConfigFile]) async -> [VMLibrary.ConfigFileRepairFailure] {
            await withCheckedContinuation { repairs.append($0) }
        }

        var libraryDirectory: URL? { nil }
    }

    @Test("A check asked for during Use Defaults leaves it under way, and the check it ends in lands")
    func aCheckDuringUseDefaultsWaitsForIt() async throws {
        let source = GatedConfigCheckSource()
        let session = ConfigCheckSession(source: source)
        let repairable = UnreadableConfigFile(
            location: .bundle(scratch.url.appendingPathComponent("VMs/A.kernova"), .configuration),
            owner: .virtualMachine("Dev"),
            problems: [
                ConfigProblem(
                    path: ConfigValuePath([.key("networkMode")]),
                    issue: .unrecognized(found: Self.unrecognized), repair: .useDefault("hostOnly"))
            ])

        session.check()
        try await waitForChange { source.checks.count == 1 }
        source.checks[0].resume(returning: [repairable])
        try await waitForChange { session.work == .idle }
        #expect(session.report?.files == [repairable])

        session.useDefaults()
        #expect(session.work == .repairing)
        try await waitForChange { source.repairs.count == 1 }

        // Another open of the window checks again while the repair runs.
        session.check()
        #expect(session.work == .repairing)
        #expect(source.checks.count == 1)

        source.repairs[0].resume(returning: [])
        try await waitForChange { source.checks.count == 2 }
        #expect(session.work == .checking(token: 2))
        source.checks[1].resume(returning: [])
        try await waitForChange { session.work == .idle }
        #expect(session.report?.files == [])
    }

    @Test("A check superseded by a later one changes nothing when it ends")
    func aSupersededCheckLandsNothing() async throws {
        let source = GatedConfigCheckSource()
        let session = ConfigCheckSession(source: source)

        session.check()
        session.check()
        try await waitForChange { source.checks.count == 2 }
        source.checks[0].resume(throwing: CocoaError(.fileReadNoPermission))
        // Queued behind the superseded check's resumption, so it has ended.
        await Task { @MainActor in }.value
        #expect(session.work == .checking(token: 2))
        #expect(session.failure == nil)

        source.checks[1].resume(returning: [])
        try await waitForChange { session.work == .idle }
        #expect(session.report?.files == [])
        #expect(session.failure == nil)
    }

    @Test("Return closes the check window; Use Defaults takes a click")
    func returnCloses() throws {
        let controller = ConfigCheckViewController(source: makeSettingsViewModel(preferences: preferences))
        controller.loadViewIfNeeded()

        #expect(try #require(findButton(titled: "Close", in: controller.view)).keyEquivalent == "\r")
        #expect(try #require(findButton(titled: "Use Defaults", in: controller.view)).keyEquivalent == "")
    }

    @Test("The report counts the files, lists each problem, and says what Use Defaults does")
    func theReportWords() throws {
        let library = scratch.url
        let repairable = UnreadableConfigFile(
            location: .bundle(library.appendingPathComponent("VMs/A.kernova"), .configuration),
            owner: .virtualMachine("Dev"),
            problems: [
                ConfigProblem(
                    path: ConfigValuePath([.key("networkMode")]),
                    issue: .unrecognized(found: Self.unrecognized), repair: .useDefault("hostOnly"))
            ])
        let unrepairable = UnreadableConfigFile(
            location: .networkList(library.appendingPathComponent("Networks.json")),
            owner: .networkList,
            problems: [ConfigProblem(path: ConfigValuePath([.key("networks")]), issue: .missing)])

        let report = ConfigCheckReport(files: [repairable, unrepairable], libraryDirectory: library)

        #expect(report.header == "Kernova can\u{2019}t read 2 config files.")
        #expect(
            report.body == """
                Dev
                  VMs/A.kernova/config.json
                  $.networkMode: \u{201C}\(Self.unrecognized)\u{201D} is not a recognized value. Default: hostOnly.

                Network list
                  Networks.json
                  $.networks: no value. Kernova can\u{2019}t repair this file.
                """)
        #expect(
            report.footer
                == "Use Defaults rewrites the repairable file with these defaults; the original moves to the Trash.")
        let clean = ConfigCheckReport(files: [], libraryDirectory: library)
        #expect(clean.header == "Kernova read every config file.")
        #expect(clean.footer == nil)
    }
}
