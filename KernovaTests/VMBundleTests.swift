import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// A VM bundle's four state files, read and committed through ``VMBundle``
/// against real files: what memory holds after a write lands or fails, what a
/// write does to a field another process changed, and what each file's coding
/// preserves.
@Suite("VMBundle Tests", .admissionGated)
@MainActor
struct VMBundleTests {
    // MARK: - Fixtures

    /// One of the four files, for the tests that hold for each.
    enum StateFile: String, CaseIterable, CustomTestStringConvertible {
        case configuration
        case hostState
        case snapshotManifest
        case usbPairings

        var testDescription: String { rawValue }

        var relativePath: String {
            switch self {
            case .configuration: VMBundleLayout.configRelativePath
            case .hostState: VMBundleLayout.hostStateRelativePath
            case .snapshotManifest: VMBundleLayout.snapshotManifestRelativePath
            case .usbPairings: VMBundleLayout.usbPairingsRelativePath
            }
        }
    }

    /// A real bundle directory holding `configuration`'s `config.json`,
    /// removed when the test finishes.
    private func withBundle(
        _ configuration: VMConfiguration = VMConfiguration(
            name: "Bundle VM", guestOS: .linux, bootMode: .efi),
        _ body: (URL) throws -> Void
    ) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernova-bundle-\(UUID().uuidString).kernova", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try VMBundleFiles(url: url, access: CoordinatedBundleFileAccess()).writeInitial(configuration)
        try body(url)
    }

    /// The bundle's files through `access`, the production access by default.
    private func files(
        _ url: URL, _ access: any VMBundleFileAccessing = CoordinatedBundleFileAccess()
    ) -> VMBundleFiles {
        VMBundleFiles(url: url, access: access)
    }

    /// What the bundle's files hold now, read the way the library reads them.
    private func onDisk(_ url: URL) throws -> VMBundleRead {
        try files(url).read()
    }

    /// A VM over the bundle at `url`, read through `access` and registered with
    /// a library — the only writer of a configuration.
    private func makeVM(at url: URL, access: any VMBundleFileAccessing) throws -> (VMLibrary, VMInstance) {
        let instance = VMInstance(
            bundle: VMBundle(try files(url, access).read()), phase: .stopped,
            preferences: makeTestPreferences())
        let library = makeWiredLibrary()
        library.wireHooks(for: instance)
        library.instances.append(instance)
        return (library, instance)
    }

    private func pairing(_ key: String) -> USBAccessoryPairing {
        USBAccessoryPairing(
            key: key, form: .serialNumber, displayName: "Drive \(key)", receptacleLabel: nil,
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func snapshot(_ name: String) -> VMSnapshot {
        VMSnapshot(name: name, createdAt: Date(timeIntervalSince1970: 1_700_000_000), macAddress: nil)
    }

    /// Commits this test's own change to `file` through the VM, answering
    /// whether it landed.
    private func commitOwnChange(to file: StateFile, of instance: VMInstance, in library: VMLibrary)
        -> Bool
    {
        guard let bundle = instance.bundle else { return false }
        switch file {
        case .configuration:
            return library.updateConfiguration(of: instance) { $0.name = "Mine" }.landed
        case .hostState:
            return (try? bundle.commitHostState { $0.displayPreference = .popOut }) != nil
        case .snapshotManifest:
            return (try? bundle.commitSnapshotManifest { $0.insert(snapshot("Mine")) }) != nil
        case .usbPairings:
            return (try? bundle.commitUSBPairings { $0.upsert(pairing("mine")) }) != nil
        }
    }

    private func holdsOwnChange(_ file: StateFile, _ read: VMBundleRead) -> Bool {
        switch file {
        case .configuration: read.configuration.name == "Mine"
        case .hostState: read.hostState.displayPreference == .popOut
        case .snapshotManifest: read.snapshotManifest.snapshots.contains { $0.name == "Mine" }
        case .usbPairings: read.usbPairings.pairing(forKey: "mine") != nil
        }
    }

    /// Another process's change to `file`, made straight to disk.
    private func changeOnDisk(_ file: StateFile, at url: URL) throws {
        let other = files(url)
        switch file {
        case .configuration: try other.update(.configuration) { $0.memorySizeInGB = 12 }
        case .hostState: try other.update(.hostState) { $0.startsAutomaticallyOnLaunch = true }
        case .snapshotManifest: try other.update(.snapshotManifest) { $0.insert(snapshot("Theirs")) }
        case .usbPairings: try other.update(.usbPairings) { $0.upsert(pairing("theirs")) }
        }
    }

    private func holdsOtherChange(_ file: StateFile, _ read: VMBundleRead) -> Bool {
        switch file {
        case .configuration: read.configuration.memorySizeInGB == 12
        case .hostState: read.hostState.startsAutomaticallyOnLaunch
        case .snapshotManifest: read.snapshotManifest.snapshots.contains { $0.name == "Theirs" }
        case .usbPairings: read.usbPairings.pairing(forKey: "theirs") != nil
        }
    }

    /// Whether what `bundle` holds for `file` is what `read` found on disk.
    private func memoryMatchesDisk(_ file: StateFile, _ bundle: VMBundle, _ read: VMBundleRead) -> Bool {
        switch file {
        case .configuration: bundle.configuration == read.configuration
        case .hostState: bundle.hostState == read.hostState
        case .snapshotManifest: bundle.snapshotManifest == read.snapshotManifest
        case .usbPairings: bundle.usbPairings == read.usbPairings
        }
    }

    // MARK: - Invariants

    @Test("A write whose replace fails leaves the committed value equal to the file", arguments: StateFile.allCases)
    func failedReplaceLeavesMemoryEqualToFile(_ file: StateFile) throws {
        try withBundle { url in
            let access = ReplaceFailingBundleFileAccess(failing: [file.relativePath])
            let (library, instance) = try makeVM(at: url, access: access)
            let bundle = try #require(instance.bundle)

            #expect(!commitOwnChange(to: file, of: instance, in: library))

            let read = try onDisk(url)
            #expect(!holdsOwnChange(file, read))
            #expect(memoryMatchesDisk(file, bundle, read))
        }
    }

    @Test(
        "A field changed on disk after load survives an unrelated write to the same file",
        arguments: StateFile.allCases)
    func aFieldChangedOnDiskSurvivesAnotherWrite(_ file: StateFile) throws {
        try withBundle { url in
            let (library, instance) = try makeVM(at: url, access: CoordinatedBundleFileAccess())
            let bundle = try #require(instance.bundle)
            try changeOnDisk(file, at: url)

            #expect(commitOwnChange(to: file, of: instance, in: library))

            let read = try onDisk(url)
            #expect(holdsOwnChange(file, read))
            #expect(holdsOtherChange(file, read))
            #expect(memoryMatchesDisk(file, bundle, read))
        }
    }

    @Test("A sidecar absent at load and present before a write keeps what it holds")
    func aSidecarCopiedInAfterLoadSurvivesAWrite() throws {
        try withBundle { url in
            let bundle = VMBundle(try onDisk(url))
            // The copy that was still arriving when the bundle was read.
            try Data(#"{"startsAutomaticallyOnLaunch":true}"#.utf8).write(
                to: VMBundleLayout(bundleURL: url).hostStateURL)

            try bundle.commitHostState { $0.displayPreference = .fullscreen }

            let read = try onDisk(url)
            #expect(read.hostState.startsAutomaticallyOnLaunch)
            #expect(read.hostState.displayPreference == .fullscreen)
            #expect(bundle.hostState == read.hostState)
        }
    }

    @Test("A pairings file that does not decode is still on disk after a read")
    func anUndecodablePairingsFileIsKept() throws {
        try withBundle { url in
            let pairingsURL = VMBundleLayout(bundleURL: url).usbPairingsURL
            let corrupt = Data("{ not json".utf8)
            try corrupt.write(to: pairingsURL)

            let read = try onDisk(url)

            #expect(read.usbPairings.isEmpty)
            #expect(read.pairingsUnreadable?.fileName == "usb-accessories.json")
            #expect(try Data(contentsOf: pairingsURL) == corrupt)
        }
    }

    @Test("A write to a pairings file that does not decode fails and leaves it in place")
    func aWriteToAnUndecodablePairingsFileFails() throws {
        try withBundle { url in
            let pairingsURL = VMBundleLayout(bundleURL: url).usbPairingsURL
            let corrupt = Data("{ not json".utf8)
            try corrupt.write(to: pairingsURL)
            let bundle = VMBundle(try onDisk(url))

            #expect(throws: UnreadableBundleFile.self) {
                try bundle.commitUSBPairings { $0.upsert(pairing("new")) }
            }

            #expect(bundle.usbPairings.isEmpty)
            #expect(try Data(contentsOf: pairingsURL) == corrupt)
        }
    }

    @Test("A configuration that no longer decodes refuses a write")
    func anUndecodableConfigurationRefusesAWrite() throws {
        try withBundle { url in
            let (library, instance) = try makeVM(at: url, access: CoordinatedBundleFileAccess())
            let before = instance.configuration
            let configURL = VMBundleLayout(bundleURL: url).configURL
            let corrupt = Data("{ not json".utf8)
            try corrupt.write(to: configURL)

            let write = library.updateConfiguration(of: instance) { $0.name = "Renamed" }

            #expect(write.failedToSave)
            #expect(instance.configuration == before)
            #expect(try Data(contentsOf: configURL) == corrupt)
        }
    }

    @Test("A write that changes nothing leaves the file untouched")
    func aNoOpWriteReplacesNothing() throws {
        try withBundle { url in
            let access = ReplaceFailingBundleFileAccess()
            let bundle = VMBundle(try files(url, access).read())

            try bundle.commitHostState { $0.displayPreference = .inline }
            try bundle.commitSnapshotManifest { $0.remove(id: UUID()) }
            try bundle.commitUSBPairings { $0.remove(key: "absent") }

            #expect(access.replacedPaths.isEmpty)
            #expect(
                !FileManager.default.fileExists(
                    atPath: VMBundleLayout(bundleURL: url).hostStateURL.path(percentEncoded: false)))
        }
    }

    @Test("A committed value is what the file holds, down to the second a date keeps")
    func aCommittedValueIsWhatTheFileHolds() throws {
        try withBundle { url in
            let bundle = VMBundle(try onDisk(url))
            let taken = VMSnapshot(
                name: "Now", createdAt: Date(timeIntervalSince1970: 1_700_000_000.75), macAddress: nil)

            try bundle.commitSnapshotManifest { $0.insert(taken) }

            #expect(bundle.snapshotManifest == (try onDisk(url)).snapshotManifest)
        }
    }

    // MARK: - Reading

    @Test("A bundle with no config.json cannot be read")
    func aMissingConfigurationThrows() throws {
        try withBundle { url in
            try FileManager.default.removeItem(at: VMBundleLayout(bundleURL: url).configURL)

            #expect(throws: UnreadableBundleFile.self) { try onDisk(url) }
        }
    }

    @Test("A bundle with no sidecars reads their defaults")
    func missingSidecarsReadAsDefaults() throws {
        try withBundle { url in
            let read = try onDisk(url)

            #expect(read.hostState == VMHostState())
            #expect(read.snapshotManifest.isEmpty)
            #expect(read.usbPairings.isEmpty)
            #expect(read.pairingsUnreadable == nil)
        }
    }

    @Test("A host state that does not decode fails the read rather than reading as the defaults")
    func anUndecodableHostStateThrows() throws {
        try withBundle { url in
            try Data("{ not json".utf8).write(to: VMBundleLayout(bundleURL: url).hostStateURL)

            #expect(throws: UnreadableBundleFile.self) { try onDisk(url) }
        }
    }

    /// Only absence means "nothing recorded": a file that is there but cannot
    /// be opened still holds state, whatever the reason it cannot be read.
    @Test("A host state that cannot be opened fails the read rather than reading as the defaults")
    func anUnopenableHostStateThrows() throws {
        try withBundle { url in
            let hostStateURL = VMBundleLayout(bundleURL: url).hostStateURL
            try files(url).update(.hostState) { $0.startsAutomaticallyOnLaunch = true }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0], ofItemAtPath: hostStateURL.path(percentEncoded: false))
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: hostStateURL.path(percentEncoded: false))
            }

            #expect(throws: UnreadableBundleFile.self) { try onDisk(url) }
        }
    }

    @Test("A snapshot manifest that does not decode fails the read rather than reading as empty")
    func anUndecodableManifestThrows() throws {
        try withBundle { url in
            let layout = VMBundleLayout(bundleURL: url)
            try FileManager.default.createDirectory(
                at: layout.snapshotsDirectoryURL, withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: layout.snapshotManifestURL)

            #expect(throws: UnreadableBundleFile.self) { try onDisk(url) }
        }
    }

    @Test("A write to a bundle that is not there fails rather than inventing one")
    func aWriteToAMissingBundleThrows() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernova-absent-\(UUID().uuidString).kernova", isDirectory: true)

        #expect(throws: (any Error).self) {
            try files(missing).update(.usbPairings) { $0.upsert(pairing("a")) }
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path(percentEncoded: false)))
    }

    // MARK: - Coding

    @Test("A committed host state reads back as itself")
    func hostStateRoundTrips() throws {
        try withBundle { url in
            var written = VMHostState(
                startsAutomaticallyOnLaunch: true, displayPreference: .popOut,
                lastFullscreenDisplayID: 0xDEAD_BEEF, agentInstallNudgeDismissed: true)
            written.applyEphemeralMode(
                enabled: true, baseline: UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF"))
            let bundle = VMBundle(try onDisk(url))

            try bundle.commitHostState { $0 = written }

            #expect(try onDisk(url).hostState == written)
        }
    }

    @Test("A host-state key the file does not carry decodes to its default")
    func hostStateAbsentKeysTakeTheirDefaults() throws {
        try withBundle { url in
            try Data(#"{"displayPreference":"fullscreen"}"#.utf8).write(
                to: VMBundleLayout(bundleURL: url).hostStateURL)

            #expect(try onDisk(url).hostState == VMHostState(displayPreference: .fullscreen))
        }
    }

    @Test("Writing the host state leaves config.json alone")
    func hostStateIsItsOwnFile() throws {
        try withBundle { url in
            let configURL = VMBundleLayout(bundleURL: url).configURL
            let configBefore = try Data(contentsOf: configURL)
            let bundle = VMBundle(try onDisk(url))

            try bundle.commitHostState { $0.startsAutomaticallyOnLaunch = true }

            #expect(try Data(contentsOf: configURL) == configBefore)
        }
    }

    @Test("Committed pairings read back as themselves")
    func pairingsRoundTrip() throws {
        try withBundle { url in
            let bundle = VMBundle(try onDisk(url))
            let written = USBAccessoryPairingSet(pairings: [
                pairing("04e8:6300:0100:0373"),
                USBAccessoryPairing(
                    key: "04e8:6300:0100@hub/Port-A@1", form: .receptacle, displayName: "Hub port",
                    receptacleLabel: "Port-USB-C@2", pairedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            ])

            try bundle.commitUSBPairings { $0 = written }

            #expect(try onDisk(url).usbPairings == written)
        }
    }

    @Test("A pairing field the file does not carry decodes to its default")
    func pairingAbsentFieldsTakeTheirDefaults() throws {
        try withBundle { url in
            try Data(
                #"{"pairings":[{"key":"k","form":"serialNumber","displayName":"Drive","pairedAt":"2026-09-12T00:00:00Z"}]}"#
                    .utf8
            ).write(to: VMBundleLayout(bundleURL: url).usbPairingsURL)

            let loaded = try onDisk(url).usbPairings

            #expect(loaded.pairings.count == 1)
            #expect(loaded.pairings.first?.receptacleLabel == nil)
        }
    }

    @Test("A pairings file holding no pairings key reads as no pairings")
    func pairingsObjectWithoutPairingsReadsAsEmpty() throws {
        try withBundle { url in
            try Data("{}".utf8).write(to: VMBundleLayout(bundleURL: url).usbPairingsURL)

            let read = try onDisk(url)

            #expect(read.usbPairings.isEmpty)
            #expect(read.pairingsUnreadable == nil)
        }
    }

    @Test("A committed manifest reads back as itself")
    func manifestRoundTrips() throws {
        try withBundle { url in
            let bundle = VMBundle(try onDisk(url))
            let taken = VMSnapshot(
                name: "Before the update", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                notes: "tools configured", macAddress: nil)
            let written = VMSnapshotManifest(snapshots: [taken], currentID: taken.id)

            try bundle.commitSnapshotManifest { $0 = written }

            #expect(try onDisk(url).snapshotManifest == written)
        }
    }

    @Test("A read snapshot carries the MAC address of the configuration it was taken under")
    func manifestCarriesEachSnapshotsMACAddress() throws {
        try withBundle { url in
            var configuration = VMConfiguration(name: "Captured", guestOS: .linux, bootMode: .efi)
            configuration.macAddress = "aa:bb:cc:dd:ee:01"
            // Listed carrying some other address, which the manifest must not keep.
            let captured = VMSnapshot(
                name: "Captured", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                macAddress: "aa:bb:cc:dd:ee:09")
            let unrecorded = snapshot("No settings")
            _ = try VMSnapshotStore().prepareSnapshot(
                bundleURL: url, snapshotID: captured.id, configuration: configuration)
            try files(url).update(.snapshotManifest) {
                $0 = VMSnapshotManifest(snapshots: [captured, unrecorded])
            }

            let loaded = try onDisk(url).snapshotManifest

            #expect(loaded.snapshot(id: captured.id)?.macAddress == "aa:bb:cc:dd:ee:01")
            #expect(loaded.snapshot(id: unrecorded.id) == unrecorded)
            // The snapshot's own configuration is where the address lives; the
            // manifest never records a second copy of it.
            let manifestData = try Data(contentsOf: VMBundleLayout(bundleURL: url).snapshotManifestURL)
            #expect(!String(decoding: manifestData, as: UTF8.self).contains("macAddress"))
        }
    }
}
