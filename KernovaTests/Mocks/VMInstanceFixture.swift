import Foundation
@testable import Kernova

/// The unregistered counterpart to ``RegisteredVMInstanceFixture`` — a
/// `VMInstance` whose bundle is read from `files`, with nothing wired into a
/// library.
@MainActor
enum VMInstanceFixture {
    /// The bundle URL is derived from the configuration `mutate` leaves behind.
    ///
    /// `hostState`, `snapshots` and `pairings` seed the bundle's files, which
    /// the instance then reads as a load would. `files` is where they live — a
    /// store of the instance's own unless the test passes one it also reads.
    static func make(
        name: String = "Test VM",
        guestOS: VMGuestOS = .linux,
        phase: VMLifecyclePhase = .stopped,
        preferences: AppPreferences = makeTestPreferences(),
        hostState: VMHostState = VMHostState(),
        snapshots: VMSnapshotManifest = VMSnapshotManifest(),
        pairings: USBAccessoryPairingSet = USBAccessoryPairingSet(),
        files: InMemoryVMBundleFiles = InMemoryVMBundleFiles(),
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        var config = VMConfiguration(
            name: name, guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi)
        mutate(&config)
        let url = bundleURL(for: config.id)
        files.seed(config, hostState: hostState, snapshots: snapshots, pairings: pairings, at: url)
        return VMInstance(
            bundle: VMBundle(read(url, from: files)), phase: phase, preferences: preferences)
    }

    /// A VM whose bundle is a real directory under the temporary directory,
    /// read and written through ``CoordinatedBundleFileAccess`` — for a test
    /// that drives the real snapshot store or reads the bundle's files back
    /// off disk. The caller takes it away again with ``removeBundle(of:)``.
    ///
    /// `snapshots` is written before the read; each snapshot's MAC address is
    /// whatever its own `config.json` on disk holds when the bundle is read.
    static func makeOnDisk(
        name: String = "Test VM",
        guestOS: VMGuestOS = .linux,
        phase: VMLifecyclePhase = .stopped,
        preferences: AppPreferences = makeTestPreferences(),
        snapshots: VMSnapshotManifest = VMSnapshotManifest(),
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) throws -> VMInstance {
        var config = VMConfiguration(
            name: name, guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi)
        mutate(&config)
        let url = bundleURL(for: config.id)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let files = VMBundleFiles(url: url, access: CoordinatedBundleFileAccess())
        try files.writeInitial(config)
        if !snapshots.snapshots.isEmpty || snapshots.currentID != nil {
            try files.update(.snapshotManifest) { $0 = snapshots }
        }
        return VMInstance(bundle: VMBundle(try files.read()), phase: phase, preferences: preferences)
    }

    /// A row whose create, clone or import has not published its bundle yet.
    static func makeArriving(
        name: String = "Test VM",
        guestOS: VMGuestOS = .linux,
        phase: VMLifecyclePhase = .stopped,
        preferences: AppPreferences = makeTestPreferences(),
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        var config = VMConfiguration(
            name: name, guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi)
        mutate(&config)
        return VMInstance(
            arriving: config, bundleURL: bundleURL(for: config.id), phase: phase,
            preferences: preferences)
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
        try Data("suspend slot".utf8).write(to: instance.saveFileURL)
    }

    /// Takes away the bundle directory a fixture wrote into.
    static func removeBundle(of instance: VMInstance) {
        try? FileManager.default.removeItem(at: instance.bundleURL)
    }
}
