import Foundation
import KernovaCommandModel
import KernovaCore
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The library's config files Kernova can't read: kept in sight as rows no
/// verb addresses, reported once, listed by the check, and repaired by Use
/// Defaults where every problem has a default.
@Suite("VMLibrary config check", .serialized, .caseScoped)
@MainActor
struct VMLibraryConfigCheckTests {
    private let preferences = makeTestPreferences()
    /// Records what Use Defaults moves to the Trash, so nothing lands in the
    /// user's own.
    private let fileSystem = MockFileSystem()

    /// A value no field of any config type takes.
    private static let unrecognized = "plan9-mode"

    /// How many times the library asked for the check to come up.
    private let checkRequests = Counter()

    @MainActor
    private final class Counter {
        var count = 0
    }

    private func makeHarness(
        networks: VMNetworkDirectory = VMNetworkDirectory(fileURL: nil),
        organization: VMOrganizationDirectory = VMOrganizationDirectory(fileURL: nil)
    ) -> WiredCommandCore {
        let wired = WiredCommandCore(
            fileSystem: fileSystem, networks: networks, organization: organization,
            preferences: preferences)
        let counter = checkRequests
        wired.library.onUnreadableFilesFound = { counter.count += 1 }
        return wired
    }

    /// A bundle whose `config.json` is `name`'s configuration with `edit`
    /// applied to its JSON; `edit` may make it unreadable.
    @discardableResult
    private func addBundle(
        _ name: String, to storage: MockVMStorageService,
        edit: (inout [String: Any]) -> Void = { _ in }
    ) throws -> (url: URL, bytes: Data) {
        let config = VMConfiguration(
            name: name, guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
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

    // MARK: - The check

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
            of: VMConfiguration(
                name: "Dev", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize)
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
                == VMConfiguration(
                    name: "", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                    memorySizeInGB: VMGuestOS.linux.hostMemorySize
                ).networkMode)
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
        let changed = try Self.json(
            of: VMConfiguration(
                name: "Dev", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        ) {
            $0["networkMode"] = "another-unrecognized-mode"
        }
        harness.storage.files.setData(changed, atRelativePath: VMBundleLayout.configRelativePath, in: url)

        let failures = await harness.library.useDefaults(in: files)

        #expect(failures.map(\.reason) == [ConfigFileRepairRefusal.changedSinceCheck.localizedDescription])
        #expect(configBytes(at: url, in: harness.storage) == changed)
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

    @Test("Move to Trash refuses a bundle whose file changed since its row was read, though still unreadable")
    func moveToTrashRefusesChangedBytes() async throws {
        let harness = makeHarness()
        let (url, _) = try addBundle("Dev", to: harness.storage) { $0["networkMode"] = Self.unrecognized }
        await harness.library.loadVMs()
        let row = try #require(harness.library.entries.compactMap(\.unreadable).first)

        let changed = try Self.json(
            of: VMConfiguration(
                name: "Dev", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        ) {
            $0["networkMode"] = "another-unrecognized-mode"
        }
        harness.storage.files.setData(changed, atRelativePath: VMBundleLayout.configRelativePath, in: url)

        await #expect(throws: ConfigFileRepairRefusal.changedSinceCheck) {
            try await harness.library.moveToTrash(row)
        }
        #expect(harness.storage.deleteVMBundleCallCount == 0)
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
                of: VMConfiguration(
                    name: "Dev", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                    memorySizeInGB: VMGuestOS.linux.hostMemorySize), edit: snapshotConfig),
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
                verb: .start(.id(instance.id), recovery: false, consent: .none)))
        #expect(response.result == .failure(refusal.dto))
        let intents = VMIntentGateway(
            commands: harness.core, readiness: LibraryReadiness(awaitReady: {}),
            index: MockVMEntityIndex(), record: makeTestIndexRecord())
        await #expect(throws: refusal) {
            try await intents.start(instance.id, recovery: false, consent: .none)
        }
        #expect(instance.status == .stopped)

        // An outside edit that makes the baseline readable is read at the
        // start's own admission.
        harness.storage.files.setData(
            try Self.json(
                of: VMConfiguration(
                    name: "Dev", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                    memorySizeInGB: VMGuestOS.linux.hostMemorySize)
            ) { _ in },
            atRelativePath: VMBundleLayout.snapshotConfigRelativePath(id: snapshotID), in: url)
        try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        try await waitForChange { instance.status == .running }
        #expect(instance.unreadableFiles.isEmpty)
    }
}
