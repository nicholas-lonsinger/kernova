import Foundation
@testable import Kernova

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
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        let read = seed(
            name: name, guestOS: guestOS, hostState: hostState, snapshots: snapshots,
            pairings: pairings, files: files, mutate: mutate)
        return VMInstance(
            bundle: (bundleFactory ?? VMBundle.Factory(machineFiles: MockVMBundleMachineFiles(files: files)))
                .make(read),
            phase: phase, preferences: preferences)
    }

    /// Seeds a fixture bundle's files into `files` and reads it back as a load
    /// would — what ``make(name:guestOS:phase:preferences:hostState:snapshots:pairings:files:bundleFactory:mutate:)``
    /// and a library's fixture admission build their bundle from.
    static func seed(
        name: String, guestOS: VMGuestOS, hostState: VMHostState, snapshots: VMSnapshotManifest,
        pairings: USBAccessoryPairingSet, files: InMemoryVMBundleFiles,
        mutate: (inout VMConfiguration) -> Void
    ) -> VMBundleRead {
        var config = VMConfiguration(
            name: name, guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi)
        mutate(&config)
        let url = bundleURL(for: config.id)
        files.seed(config, hostState: hostState, snapshots: snapshots, pairings: pairings, at: url)
        return read(url, from: files)
    }

    /// Writes a fixture bundle as a real directory under the temporary
    /// directory, read and written through ``CoordinatedBundleFileAccess``,
    /// and reads it back as a load would — for a test that drives the real
    /// machine files or reads the bundle's files back off disk. The caller
    /// takes it away again with ``removeBundle(of:)``.
    ///
    /// `snapshots` is written before the read; each snapshot's MAC address is
    /// whatever its own `config.json` on disk holds when the bundle is read.
    static func seedOnDisk(
        name: String, guestOS: VMGuestOS, snapshots: VMSnapshotManifest,
        mutate: (inout VMConfiguration) -> Void
    ) throws -> VMBundleRead {
        var config = VMConfiguration(
            name: name, guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi)
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
    nonisolated static func bundleURL(for id: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(id.uuidString).kernova", isDirectory: true)
    }

    /// Puts a suspend slot in `instance`'s bundle, creating the bundle
    /// directory — what every predicate that follows the file reads
    /// (``VMInstance/holdsSuspendedSession``).
    ///
    /// The bundle is a real directory under the temporary directory, so a test
    /// that writes one takes it away again with ``removeBundle(of:)``.
    static func writeSaveFile(for instance: VMInstance) throws {
        try FileManager.default.createDirectory(
            at: instance.bundleURL, withIntermediateDirectories: true)
        try Data("suspend slot".utf8).write(to: instance.bundleLayout.saveFileURL)
    }

    /// Takes away the bundle directory a fixture wrote into.
    static func removeBundle(of instance: VMInstance) {
        try? FileManager.default.removeItem(at: instance.bundleURL)
    }
}
