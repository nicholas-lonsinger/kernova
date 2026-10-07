import Cocoa
import Foundation
import KernovaKit
import KernovaTestSupport
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

    private func makeHarness(networks: VMNetworkDirectory = VMNetworkDirectory(fileURL: nil))
        -> Harness
    {
        let storage = MockVMStorageService()
        let lifecycle = makeTestLifecycle(
            virtualization: MockVirtualizationService(), fileSystem: fileSystem)
        let library = makeWiredLibrary(
            storage: storage, machineFiles: MockVMBundleMachineFiles(files: storage.files),
            lifecycle: lifecycle, fileSystem: fileSystem, preferences: preferences,
            networks: networks)
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
        ) { $0["networkMode"] = Self.unrecognized }
        let snapshotPath = VMBundleLayout.snapshotConfigRelativePath(id: snapshotID)
        harness.storage.files.setData(snapshotConfig, atRelativePath: snapshotPath, in: url)
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
        #expect(fileSystem.trashedURLs.map(\.lastPathComponent) == ["config.json"])
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
        #expect(fileSystem.trashedURLs.map(\.lastPathComponent) == ["config.json"])
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

    @Test("The report counts the files, lists each problem, and says what Use Defaults does")
    func theReportWords() throws {
        let library = scratch.url
        let repairable = UnreadableConfigFile(
            location: .bundle(library.appendingPathComponent("VMs/A.kernova"), .configuration),
            owner: .virtualMachine("Dev"),
            problems: [
                ConfigProblem(
                    path: ConfigValuePath([.key("networkMode")]),
                    issue: .unrecognized(found: Self.unrecognized, default: "hostOnly"))
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
