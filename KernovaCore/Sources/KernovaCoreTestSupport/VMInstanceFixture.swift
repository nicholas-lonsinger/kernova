import Foundation
import KernovaAgentHost
import KernovaCommandModel

#if SWIFT_PACKAGE
import KernovaTestSupport
#endif

@testable import KernovaCore

/// A `VMInstance` whose bundle is read from `files`, with nothing wired into a
/// library, and the bundle a library builds its own fixture VMs from —
/// ``VMLibrary/admitFixture(name:guestOS:phase:preferences:hostState:snapshots:pairings:files:mutate:)``.
@MainActor
enum VMInstanceFixture {
    /// The bundle URL is derived from the configuration `mutate` leaves behind.
    ///
    /// `hostState`, `snapshots` and `pairings` seed the bundle's files, which
    /// the instance then reads as a load would. `files` is where they live — a
    /// store of the instance's own unless the test passes one it also reads.
    /// `bundleFactory` builds the bundle — over a ``MockVMBundleMachineFiles``
    /// of the instance's own unless the test passes a factory over one it
    /// also reads.
    static func make(
        name: String = "Test VM",
        guestOS: VMGuestOS = .linux,
        phase: VMLifecyclePhase = .stopped,
        preferences: AppPreferences = makeTestPreferences(),
        hostState: VMHostState = VMHostState(),
        snapshots: VMSnapshotManifest = VMSnapshotManifest(),
        pairings: USBAccessoryPairingSet = USBAccessoryPairingSet(),
        files: InMemoryVMBundleFiles = InMemoryVMBundleFiles(),
        bundleFactory: VMBundle.Factory? = nil,
        agentConnector: (any HostConnectionMaking)? = nil,
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        let read = seed(
            name: name, guestOS: guestOS, hostState: Self.hostState(hostState, placedAt: phase),
            snapshots: snapshots, pairings: pairings, files: files, mutate: mutate)
        let instance = VMInstance(
            bundle: (bundleFactory ?? VMBundle.Factory(machineFiles: MockVMBundleMachineFiles(files: files)))
                .make(read),
            phase: phase, preferences: preferences,
            hostPasteboard: FakePasteboard(), bundleProducts: .testing, logSink: nil,
            agentConnector: agentConnector)
        // A VM neither at rest nor removed holds its run lock.
        if !phase.isAtRest, phase != .removed { instance.activity.takeRunLockForTesting() }
        return instance
    }

    /// `hostState` as a VM placed at `phase` holds it: a phase holding a
    /// session is one a bring-up began, which left that session unsettled
    /// (``VMHostState/hasUnsettledSession``).
    static func hostState(_ hostState: VMHostState, placedAt phase: VMLifecyclePhase) -> VMHostState {
        guard phase.sessionID != nil else { return hostState }
        var placed = hostState
        placed.hasUnsettledSession = true
        return placed
    }

    /// A fresh configuration for a `guestOS` VM named `name`, with the
    /// resources the creation wizard gives one on this Mac — inside the bounds
    /// a configuration write is checked against.
    static func makeConfiguration(name: String, guestOS: VMGuestOS) -> VMConfiguration {
        VMConfiguration(
            name: name, guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi,
            cpuCount: guestOS.hostCPUCount, memorySizeInGB: guestOS.hostMemorySize)
    }

    /// Seeds a fixture bundle's files into `files` and reads it back as a load
    /// would — what ``make(name:guestOS:phase:preferences:hostState:snapshots:pairings:files:bundleFactory:agentConnector:mutate:)``
    /// and a library's fixture admission build their bundle from.
    static func seed(
        name: String, guestOS: VMGuestOS, hostState: VMHostState, snapshots: VMSnapshotManifest,
        pairings: USBAccessoryPairingSet, files: InMemoryVMBundleFiles,
        mutate: (inout VMConfiguration) -> Void
    ) -> VMBundleRead {
        var config = makeConfiguration(name: name, guestOS: guestOS)
        mutate(&config)
        let url = bundleURL(for: config.id)
        files.seed(config, hostState: hostState, snapshots: snapshots, pairings: pairings, at: url)
        return read(url, from: files)
    }

    /// Writes a fixture bundle as a real directory at ``bundleURL(for:)``,
    /// read and written through ``CoordinatedBundleFileAccess``, and reads it
    /// back as a load would — for a test that drives the real machine files or
    /// reads the bundle's files back off disk.
    ///
    /// `snapshots` is written before the read; each snapshot's MAC address is
    /// whatever its own `config.json` on disk holds when the bundle is read.
    static func seedOnDisk(
        name: String, guestOS: VMGuestOS, snapshots: VMSnapshotManifest,
        mutate: (inout VMConfiguration) -> Void
    ) throws -> VMBundleRead {
        var config = makeConfiguration(name: name, guestOS: guestOS)
        mutate(&config)
        let url = bundleURL(for: config.id)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let access = CoordinatedBundleFileAccess()
        let writer = VMStagedBundle.fixtureForTesting(at: url, access: access)
        try writer.writeInitial(config)
        if !snapshots.snapshots.isEmpty || snapshots.currentID != nil {
            try writer.update(.snapshotManifest) { $0 = snapshots }
        }
        return try VMBundleFiles(url: url, access: access).read()
    }

    /// What the bundle at `url` holds, read the way the library reads it.
    static func read(_ url: URL, from files: any VMBundleFileAccessing) -> VMBundleRead {
        do {
            return try VMBundleFiles(url: url, access: files).read()
        } catch {
            preconditionFailure("A fixture bundle could not be read: \(error)")
        }
    }

    /// The bundle a fixture VM with identifier `id` lives at — for a
    /// configuration that names paths inside it before the instance exists.
    /// It sits in the running test case's own scratch, which the case's end
    /// removes.
    nonisolated static func bundleURL(for id: UUID) -> URL {
        TestScratchDirectory.forCase(prefix: "VMFixtures").url
            .appendingPathComponent("\(id.uuidString).kernova", isDirectory: true)
    }

    /// Puts a suspend slot in `instance`'s bundle, creating the bundle
    /// directory — what every predicate that follows the file reads
    /// (``VMInstance/holdsSuspendedSession``).
    static func writeSaveFile(for instance: VMInstance) throws {
        try FileManager.default.createDirectory(
            at: instance.bundleURL, withIntermediateDirectories: true)
        try Data("suspend slot".utf8).write(to: instance.bundleLayout.saveFileURL)
    }
}

extension VMBundle.Factory {
    /// A factory for fixture bundles no library holds: their configuration
    /// policy is a library's, over parts no library wires, so it has no VMs
    /// to refuse a MAC address against or to watch.
    @MainActor
    init(machineFiles: any VMBundleMachineFileWorking) {
        let guestAddresses = GuestAddressObserver(
            reader: ScriptedARPTable(), vmnetNetworks: .scripted(), entitlements: .entitled)
        self.init(
            machineFiles: machineFiles,
            configurationPolicy: VMLibraryConfigurationPolicy(
                macAddresses: VMMACAddressRegistry(),
                removableMedia: VMRemovableMediaReconciler(lifecycle: makeTestLifecycle()),
                guestAddresses: guestAddresses))
    }
}

extension VMGuestOS {
    /// The CPU count the creation wizard gives a new guest of this OS on this
    /// Mac.
    var hostCPUCount: Int { defaultCPUCount(within: FakeVirtualizationHost.resourceLimits) }

    /// The memory the creation wizard gives a new guest of this OS on this Mac.
    var hostMemorySize: VMMemorySize { defaultMemorySize(within: FakeVirtualizationHost.resourceLimits) }
}
