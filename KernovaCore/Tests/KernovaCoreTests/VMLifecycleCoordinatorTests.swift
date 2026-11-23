import CryptoKit
import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Observation
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMLifecycleCoordinator Tests", .caseScoped)
@MainActor
struct VMLifecycleCoordinatorTests {
    private let scratch = TestScratchDirectory(prefix: "VMLifecycleCoordinatorTests")
    /// A destination the wizard previewed for an older build than the one the
    /// install resolves.
    private static let olderBuildFilename = "UniversalMac_26.4_25E200_Restore.ipsw"

    /// The pinned catalog image the `.catalogVersion` cases install from.
    private static let pinnedRestoreImageURL = URL(
        string: "https://updates.cdn-apple.com/x/UniversalMac_15.6.1_24G90_Restore.ipsw")

    /// `downloadsDirectory` moves the coordinator's Downloads-only destination
    /// invariant to a test-owned directory, so destination tests can name paths
    /// that must be honored without touching the user's Downloads.
    private func makeCoordinator(
        downloadsDirectory: URL = makeTestDownloadsDirectory()
    ) -> (
        VMLifecycleCoordinator,
        MockVirtualizationService,
        MockMacOSInstallService,
        MockIPSWService,
        MockRemovableMediaDeviceService,
        MockDownloadService
    ) {
        let virtService = MockVirtualizationService()
        let installService = MockMacOSInstallService()
        let ipswService = MockIPSWService()
        let removableMediaService = MockRemovableMediaDeviceService()
        let downloadService = MockDownloadService()
        let coordinator = makeTestLifecycle(
            virtualization: virtService, installService: installService, ipswService: ipswService,
            removableMedia: removableMediaService, downloadService: downloadService,
            downloadsDirectory: downloadsDirectory)
        return (
            coordinator, virtService, installService, ipswService, removableMediaService,
            downloadService
        )
    }

    private func makeSuspendingCoordinator() -> (
        VMLifecycleCoordinator,
        SuspendingMockVirtualizationService
    ) {
        let suspendingService = SuspendingMockVirtualizationService()
        let coordinator = makeTestLifecycle(virtualization: suspendingService)
        return (coordinator, suspendingService)
    }

    // MARK: - Lifecycle Forwarding

    private static let coldBoot = VMGuestStartKind.starting(recovery: false)

    // MARK: - One Operation per VM

    @Test("a snapshot delete during another operation is rejected, not run")
    func rejectsSnapshotDeleteDuringAnotherOperation() async throws {
        let (coordinator, suspendingService) = makeSuspendingCoordinator()
        let store = MockVMBundleMachineFiles()
        let instance = VMInstanceFixture.make(bundleFactory: VMBundle.Factory(machineFiles: store))

        let task = Task { @MainActor in
            try await coordinator.launchStart(instance, Self.coldBoot).resolved()
        }
        try await suspendingService.waitUntilSuspended()

        // A revert reads the very directory this would move to the Trash.
        await #expect(throws: VMAdmissionRefusal(refusal: .busy(.bringUp(.guestStart(Self.coldBoot))))) {
            try await coordinator.discardSnapshot(instance, snapshotID: UUID()) { _ in }
        }
        #expect(store.discardedIDs.isEmpty)

        suspendingService.resumeSuspended()
        _ = try await task.joined()
    }

    // MARK: - macOS Installation

    @Test("A Download Latest VM created after a failed lookup is named, and its name kept, at Start")
    func installMacOSLatestWithNoStoredDestination() async throws {
        // Read on the failure path: a successful install clears the context.
        let downloads = scratch.url
            .appendingPathComponent("latestUnnamed", isDirectory: true)
        let (coordinator, _, _, ipswService, _, downloadService) = makeCoordinator(
            downloadsDirectory: downloads)
        downloadService.setDownloadError(DownloadError.downloadFailed(URLError(.notConnectedToInternet)))
        let failing = MockIPSWService()
        failing.fetchError = URLError(.notConnectedToInternet)
        let wizard = VMCreationViewModel.overFakeEngine(
            probeService: MockRestoreImageProbeService(), ipswService: failing,
            downloadsDirectory: downloads)
        try await wizard.loadLatestImageDetails()?.joined()
        var context = wizard.buildInstallContext()
        #expect(context.source == .downloadLatest)
        #expect(context.downloadDestinationPath == nil)
        // A confirmation can only be about a file the wizard named; one carried
        // with no file named lapses, as one about a moved file does.
        context.requestedFreshDownload = true
        let library = makeWiredLibrary()
        let instance = library.registerFixture { $0.installContext = context }
        defer { withExtendedLifetime(library) {} }

        await #expect(throws: DownloadError.self) {
            try await coordinator.launchGuestSetup(on: instance).resolved()
        }

        let expected = downloads.appendingPathComponent(
            RestoreImageFilename.destination(for: ipswService.fetchResult.url))
        #expect(downloadService.lastDownloadDestinationURL == expected)
        #expect(downloadService.lastDownloadDiscardsExisting == false)
        #expect(downloadService.discardResumeDataCallCount == 0)
        #expect(
            instance.configuration.installContext?.downloadDestinationPath
                == expected.path(percentEncoded: false))
        #expect(instance.configuration.installContext?.requestedFreshDownload == false)
    }

    @Test("A latest destination that moved keeps the old bundle while another VM's setup targets it")
    func installMacOSLatestKeepsSharedResumeDataOnAMove() async {
        // The other VM's setup still downloads into the old path — streaming
        // into its bundle, or waiting to resume from it — so the move abandons
        // the old path for this VM only.
        // Read on the failure path: a successful install clears the context.
        let downloads = scratch.url
            .appendingPathComponent("latestSharedMove", isDirectory: true)
        let (coordinator, _, _, ipswService, _, downloadService) = makeCoordinator(
            downloadsDirectory: downloads)
        downloadService.setDownloadError(DownloadError.downloadFailed(URLError(.notConnectedToInternet)))
        let persisted = downloads.appendingPathComponent(Self.olderBuildFilename)
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: persisted.path(percentEncoded: false)
        )
        let library = makeWiredLibrary()
        let instance = library.registerFixture(name: "Moving") { $0.installContext = context }
        library.registerFixture(name: "Staying") { $0.installContext = context }
        defer { withExtendedLifetime(library) {} }

        await #expect(throws: DownloadError.self) {
            try await coordinator.launchGuestSetup(on: instance).resolved()
        }

        let expected = downloads.appendingPathComponent(
            RestoreImageFilename.destination(for: ipswService.fetchResult.url))
        #expect(
            instance.configuration.installContext?.downloadDestinationPath
                == expected.path(percentEncoded: false))
        #expect(downloadService.discardResumeDataCallCount == 0)
    }

    @Test("A latest destination that moved lapses Download & Replace rather than retargeting it")
    func installMacOSLatestFreshDownloadLapsesOnAMovedDestination() async {
        // "Download & Replace" was confirmed in the wizard against the
        // destination shown there. When the install resolves a newer image, the
        // file at the derived destination is one the user never saw, so
        // honoring the flag would trash bytes nobody agreed to lose.
        // Read on the failure path: a successful install clears the context.
        let temp = scratch.url
            .appendingPathComponent("freshDownloadMoved", isDirectory: true)
        let (coordinator, _, _, ipswService, _, downloadService) = makeCoordinator(downloadsDirectory: temp)
        downloadService.setDownloadError(DownloadError.downloadFailed(URLError(.notConnectedToInternet)))

        let persisted = temp.appendingPathComponent(Self.olderBuildFilename)
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: persisted.path(percentEncoded: false),
            requestedFreshDownload: true
        )
        let library = makeWiredLibrary()
        let instance = library.registerFixture { $0.installContext = context }
        defer { withExtendedLifetime(library) {} }

        await #expect(throws: DownloadError.self) {
            try await coordinator.launchGuestSetup(on: instance).resolved()
        }

        let derived = temp.appendingPathComponent(
            RestoreImageFilename.destination(for: ipswService.fetchResult.url))
        #expect(downloadService.lastDownloadDestinationURL == derived)
        #expect(downloadService.lastDownloadDiscardsExisting == false)
        // The lapse spares the file at the *derived* destination; the sidecar
        // left at the path being abandoned is still discarded.
        #expect(downloadService.discardResumeDataCallCount == 1)
        #expect(downloadService.discardedResumeDataURLs.last == persisted)
        // The lapse is persisted with the re-pointed path, so the retry Start
        // that reads this context does not resurrect the confirmation.
        #expect(
            instance.configuration.installContext?.downloadDestinationPath
                == derived.path(percentEncoded: false))
        #expect(instance.configuration.installContext?.requestedFreshDownload == false)
    }

    @Test("installMacOS clears requestedFreshDownload before the download runs")
    func installMacOSFreshDownloadClearsTheFlagOnce() async {
        // A download that fails leaves the context for the retry Start — with
        // the flag already spent, so the retry resumes the partial rather than
        // trashing it and starting over.
        let temp = scratch.url
            .appendingPathComponent("freshDownloadOnce", isDirectory: true)
        let (coordinator, _, _, ipswService, _, downloadService) = makeCoordinator(downloadsDirectory: temp)
        downloadService.setDownloadError(DownloadError.downloadFailed(URLError(.notConnectedToInternet)))

        // Honored, not lapsed: the persisted destination is already the one the
        // resolved image derives.
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: temp.appendingPathComponent(
                RestoreImageFilename.destination(for: ipswService.fetchResult.url)
            ).path(percentEncoded: false),
            requestedFreshDownload: true
        )
        let library = makeWiredLibrary()
        let instance = library.registerFixture { $0.installContext = context }
        defer { withExtendedLifetime(library) {} }

        await #expect(throws: DownloadError.self) {
            try await coordinator.launchGuestSetup(on: instance).resolved()
        }

        #expect(downloadService.lastDownloadDiscardsExisting == true)
        #expect(instance.configuration.installContext?.requestedFreshDownload == false)
    }

    @Test("installMacOS rejects requestedFreshDownload on a non-IPSW path")
    func installMacOSFreshDownloadRejectsNonIPSWPath() async throws {
        // The non-IPSW file sits inside the (injected) Downloads directory —
        // an out-of-Downloads path would be normalized to the pinned image's
        // filename before this guard is reached. A pinned source is what keeps
        // such a path: "Download Latest" always names its destination from the
        // URL it resolved, which is always an `.ipsw`.
        let temp = scratch.url
            .appendingPathComponent("rejectNonIPSW", isDirectory: true)
        let (coordinator, _, _, _, _, downloadService) = makeCoordinator(downloadsDirectory: temp)
        // Path doesn't end in .ipsw — guard must fire before any trash attempt.
        let context = MacOSInstallContext(
            source: .catalogVersion,
            downloadDestinationPath: temp.appendingPathComponent("important.doc")
                .path(percentEncoded: false),
            requestedFreshDownload: true,
            remoteURL: Self.pinnedRestoreImageURL
        )
        let library = makeWiredLibrary()
        let instance = library.registerFixture { $0.installContext = context }
        defer { withExtendedLifetime(library) {} }

        do {
            try await coordinator.launchGuestSetup(on: instance).resolved()
            Issue.record("Expected invalidDownloadDestination")
        } catch DownloadError.invalidDownloadDestination {
            #expect(instance.status == .error)
            #expect(downloadService.discardResumeDataCallCount == 0)
            #expect(downloadService.downloadCallCount == 0)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Linux Installer Image

    /// The Linux pipeline's own seams, over a test-owned Downloads directory
    /// the download mock really writes into — verification reads the file back,
    /// so nothing here can be faked with a path alone.
    private struct LinuxFixture {
        let coordinator: VMLifecycleCoordinator
        let resolveService: MockLinuxImageResolveService
        let downloadService: MockDownloadService
        let fileSystem: MockFileSystem
        let downloads: URL
        /// The bytes the download writes and the digest they hash to.
        let contents: Data
        let digest: String
        let library: VMLibrary
        let storage: MockVMStorageService
    }

    private func makeLinuxFixture() throws -> LinuxFixture {
        let downloads = scratch.url
            .appendingPathComponent("linuxImage", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

        let contents = Data("kernova linux image fixture".utf8)
        let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()

        let resolveService = MockLinuxImageResolveService()
        resolveService.resolveResult = makeResolvedLinuxImage(sizeBytes: UInt64(contents.count))
        resolveService.manifestSHA256 = digest
        let downloadService = MockDownloadService()
        downloadService.setDownloadedContents(contents)
        let fileSystem = MockFileSystem()

        let coordinator = makeTestLifecycle(
            linuxImageResolveService: resolveService, downloadService: downloadService,
            fileSystem: fileSystem, downloadsDirectory: downloads)
        let storage = MockVMStorageService()
        return LinuxFixture(
            coordinator: coordinator, resolveService: resolveService,
            downloadService: downloadService, fileSystem: fileSystem, downloads: downloads,
            contents: contents, digest: digest,
            library: makeWiredLibrary(storage: storage), storage: storage)
    }

    /// A Linux VM carrying `context`, registered in `fixture`'s library.
    private func makeLinuxInstance(
        context: LinuxInstallContext, in fixture: LinuxFixture,
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        let instance = fixture.library.registerFixture(name: "Debian") {
            $0.linuxInstallContext = context
            mutate(&$0)
        }
        instance.activity.placeForTesting(.initialBoot)
        return instance
    }

    @Test("downloadLinuxImage resolves, downloads, verifies and attaches the ISO")
    func downloadLinuxImageHappyPath() async throws {
        let fixture = try makeLinuxFixture()
        let entry = makeLinuxCatalogEntry()
        let instance = makeLinuxInstance(
            context: LinuxInstallContext(source: .catalogEntry(entry)), in: fixture)

        try await fixture.coordinator.launchGuestSetup(on: instance).resolved()

        let expected = fixture.downloads.appendingPathComponent(
            fixture.resolveService.resolveResult.destinationFilename)
        #expect(fixture.resolveService.resolveCallCount == 1)
        #expect(fixture.resolveService.lastResolvedEntry == entry)
        #expect(fixture.downloadService.lastDownloadRemoteURL == fixture.resolveService.resolveResult.isoURL)
        #expect(fixture.downloadService.lastDownloadDestinationURL == expected)
        // The resolution's own size is the ceiling the transfer is held to.
        #expect(
            fixture.downloadService.lastDownloadExpectedSizeBytes
                == fixture.resolveService.resolveResult.sizeBytes)

        // The installer boots ahead of the synthesized main disk, read-only and
        // on the USB bus its `.iso` extension implies.
        let disks = try #require(instance.configuration.storageDisks)
        #expect(disks.count == 2)
        #expect(disks[0].path == expected.path(percentEncoded: false))
        #expect(disks[0].readOnly)
        #expect(disks[0].kind == .usbMassStorage)
        // Labelled for the image the mirror published, not for the
        // discriminated filename the bytes landed in.
        #expect(disks[0].label == "debian-13.6.0-arm64-netinst")
        #expect(disks[1].label == "Main Disk")
        #expect(disks[1].isInternal)
        #expect(
            instance.configuration.installedImage
                == .linuxCatalogImage(
                    distribution: entry.distribution, version: entry.version,
                    digest: try matchedDigest(fixture, source: .checksumList(entry.manifestURL))))

        // The intent is spent: the next Start takes the normal boot path.
        #expect(instance.configuration.linuxInstallContext == nil)
        #expect(instance.setupState == nil)
        #expect(fixture.fileSystem.trashedURLs.isEmpty)
        // The pipeline put the VM in `.installing`; it has to come to rest in a
        // status the auto-boot chained off this return can start from.
        #expect(instance.status == .stopped)
    }

    /// The record of the fixture's bytes matching `source`.
    private func matchedDigest(
        _ fixture: LinuxFixture, source: DigestSource
    ) throws -> InstallerImageDigest {
        try #require(
            ExpectedDigest(sha256: fixture.digest, source: source)
                .match(fixture.digest, filename: fixture.resolveService.resolveResult.filename))
    }

    @Test("downloadLinuxImage persists the destination before the download runs")
    func downloadLinuxImagePersistsDestination() async throws {
        // Read on the failure path: a successful run clears the context.
        let fixture = try makeLinuxFixture()
        fixture.downloadService.setDownloadError(
            DownloadError.downloadFailed(
                URLError(.notConnectedToInternet)))
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context, in: fixture)

        await #expect(throws: DownloadError.self) {
            try await fixture.coordinator.launchGuestSetup(on: instance).resolved()
        }

        let expected = fixture.downloads.appendingPathComponent(
            fixture.resolveService.resolveResult.destinationFilename)
        #expect(
            instance.configuration.linuxInstallContext?.downloadDestinationPath
                == expected.path(percentEncoded: false))
        #expect(instance.status == .error)
        #expect(instance.configuration.installedImage == nil)
    }

    @Test("A persisted destination outside Downloads is replaced by the resolved filename")
    func downloadLinuxImageRederivesDestination() async throws {
        let fixture = try makeLinuxFixture()
        // A hand-edited config.json, and a name from a resolution that has since
        // been superseded: neither may decide where the bytes land.
        let stale = URL(fileURLWithPath: "/Users/Shared/../../etc/passwd")
        let context = LinuxInstallContext(
            source: .catalogEntry(makeLinuxCatalogEntry()),
            downloadDestinationPath: stale.path(percentEncoded: false))
        let instance = makeLinuxInstance(context: context, in: fixture)

        try await fixture.coordinator.launchGuestSetup(on: instance).resolved()

        let expected = fixture.downloads.appendingPathComponent(
            fixture.resolveService.resolveResult.destinationFilename)
        #expect(fixture.downloadService.lastDownloadDestinationURL == expected)
        // The partial at the abandoned path can never be resumed, so it goes
        // before the only pointer to it moves.
        #expect(fixture.downloadService.discardedResumeDataURLs == [stale])
    }

    @Test("A moved Linux resolution keeps the old bundle while another VM's setup targets it")
    func downloadLinuxImageKeepsSharedResumeDataOnAMove() async throws {
        let fixture = try makeLinuxFixture()
        // A resolution since superseded by the mirror's rename.
        let previous = fixture.downloads.appendingPathComponent("debian-previous.iso")
        let context = LinuxInstallContext(
            source: .catalogEntry(makeLinuxCatalogEntry()),
            downloadDestinationPath: previous.path(percentEncoded: false))
        let instance = makeLinuxInstance(context: context, in: fixture)
        _ = makeLinuxInstance(context: context, in: fixture)

        try await fixture.coordinator.launchGuestSetup(on: instance).resolved()

        let expected = fixture.downloads.appendingPathComponent(
            fixture.resolveService.resolveResult.destinationFilename)
        #expect(fixture.downloadService.lastDownloadDestinationURL == expected)
        #expect(fixture.downloadService.discardResumeDataCallCount == 0)
    }

    @Test("A checksum mismatch trashes the image, discards its bundle, and keeps the context")
    func downloadLinuxImageChecksumMismatch() async throws {
        let fixture = try makeLinuxFixture()
        // The mirror's manifest and the bytes disagree — a truncated or
        // tampered-with download.
        fixture.resolveService.manifestSHA256 = String(repeating: "a", count: 64)
        let entry = makeLinuxCatalogEntry()
        let context = LinuxInstallContext(source: .catalogEntry(entry))
        let instance = makeLinuxInstance(context: context, in: fixture)

        let expected = fixture.downloads.appendingPathComponent(
            fixture.resolveService.resolveResult.destinationFilename)
        do {
            try await fixture.coordinator.launchGuestSetup(on: instance).resolved()
            Issue.record("Expected checksumMismatch")
        } catch let error as DownloadError {
            guard case .checksumMismatch(let filename, let expected, let actual) = error else {
                Issue.record("Expected checksumMismatch, got \(error)")
                return
            }
            // The name the mirror published, which is what the user is shown —
            // not the discriminated name the bytes were written to.
            #expect(filename == fixture.resolveService.resolveResult.filename)
            // The digest the manifest stated, and where, against what the
            // bytes hash to.
            #expect(
                expected
                    == ExpectedDigest(
                        sha256: String(repeating: "a", count: 64),
                        source: .checksumList(entry.manifestURL)))
            #expect(actual == fixture.digest)
            #expect(
                error.localizedDescription
                    == "\(filename) doesn't match the checksum list on cdimage.debian.org. Try downloading it again.")
        }

        // Left in place the bad file would satisfy the skip-existing fast path
        // on every retry, so it goes, and the retry re-resolves from scratch.
        #expect(fixture.fileSystem.trashedURLs == [expected])
        #expect(fixture.downloadService.discardedResumeDataURLs == [expected])
        #expect(instance.configuration.linuxInstallContext != nil)
        #expect(instance.status == .error)
        #expect(instance.errorMessage != nil)
        #expect(instance.configuration.storageDisks == nil)
    }

    // MARK: - Adopting a File Already in Downloads

    @Test("A same-named file of the right length but the wrong bytes is downloaded past")
    func downloadLinuxImageRefusesAMatchingLengthImposter() async throws {
        let fixture = try makeLinuxFixture()
        // Everything the cheap checks can see agrees; only the digest does not.
        let resolved = fixture.resolveService.resolveResult
        let usersFile = fixture.downloads.appendingPathComponent(resolved.filename)
        let usersBytes = Data(repeating: 0x41, count: fixture.contents.count)
        try usersBytes.write(to: usersFile)
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context, in: fixture)

        try await fixture.coordinator.launchGuestSetup(on: instance).resolved()

        let destination = fixture.downloads.appendingPathComponent(resolved.destinationFilename)
        #expect(fixture.downloadService.adoptExistingFileCallCount == 0)
        #expect(fixture.downloadService.downloadCallCount == 1)
        #expect(fixture.downloadService.lastDownloadDestinationURL == destination)
        // A file that failed a digest that was never its own is still the
        // user's, so nothing happens to it.
        #expect(try Data(contentsOf: usersFile) == usersBytes)
        #expect(fixture.fileSystem.trashedURLs.isEmpty)
        #expect(instance.status == .stopped)
    }

    // MARK: - Linux Installer Image From a URL

    /// A pasted-URL context naming the image the fixture's resolve answers with.
    private func makeCustomURLContext(
        fixture: LinuxFixture, verified: Bool
    ) -> LinuxInstallContext {
        LinuxInstallContext(
            source: .customURL(
                CustomLinuxImage(
                    url: fixture.resolveService.resolveResult.isoURL,
                    sha256: verified ? fixture.digest : nil)))
    }

    @Test("A URL pick with no digest computes its checksum and records it unchecked")
    func downloadLinuxImageFromUnverifiedURL() async throws {
        let fixture = try makeLinuxFixture()
        // With no digest supplied there is nothing to hold the bytes to, which
        // is what the wizard told the user.
        let context = makeCustomURLContext(fixture: fixture, verified: false)
        let instance = makeLinuxInstance(context: context, in: fixture)

        var observedStepIDs: [SetupStepID] = []
        let persist = instance.onUpdateConfiguration
        instance.onUpdateConfiguration = { permit, mutate in
            if let id = instance.setupState?.currentStep?.id { observedStepIDs.append(id) }
            return persist?(permit, mutate) ?? .refused(.noLibrary)
        }

        try await fixture.coordinator.launchGuestSetup(on: instance).resolved()

        #expect(observedStepIDs == [.download, .checksum])
        #expect(instance.configuration.storageDisks?.count == 2)
        #expect(instance.configuration.linuxInstallContext == nil)
        #expect(fixture.fileSystem.trashedURLs.isEmpty)
        #expect(instance.status == .stopped)
        #expect(
            instance.configuration.installedImage
                == .linuxURLImage(
                    url: fixture.resolveService.resolveResult.isoURL,
                    digest: .unchecked(
                        filename: fixture.resolveService.resolveResult.filename,
                        sha256: fixture.digest)))
    }

    @Test("A URL pick whose bytes miss the supplied digest is trashed, not attached")
    func downloadLinuxImageFromURLChecksumMismatch() async throws {
        let fixture = try makeLinuxFixture()
        let wrong = String(repeating: "0", count: 64)
        let context = LinuxInstallContext(
            source: .customURL(
                CustomLinuxImage(
                    url: fixture.resolveService.resolveResult.isoURL, sha256: wrong)))
        let instance = makeLinuxInstance(context: context, in: fixture)

        let error = await #expect(throws: DownloadError.self) {
            try await fixture.coordinator.launchGuestSetup(on: instance).resolved()
        }
        guard case .checksumMismatch(let filename, let expectedDigest, _) = error else {
            Issue.record("Expected checksumMismatch, got \(String(describing: error))")
            return
        }
        #expect(expectedDigest.source == .enteredByUser)
        #expect(
            error?.localizedDescription
                == "\(filename) doesn't match the checksum you entered. "
                + "To use a different checksum, create the virtual machine again.")

        // Left in place it would satisfy the skip-existing fast path forever.
        let expected = fixture.downloads.appendingPathComponent(
            fixture.resolveService.resolveResult.destinationFilename)
        #expect(fixture.fileSystem.trashedURLs == [expected])
        #expect(instance.configuration.storageDisks == nil)
        // The intent survives for the next Start, its destination now persisted.
        #expect(instance.configuration.linuxInstallContext?.source == context.source)
        #expect(instance.status == .error)
    }

    // MARK: - Download Destination Normalization

    @Test("Every destination a hand-edited config can name lands inside Downloads")
    func normalizedDownloadDestinationContainsEveryCandidate() throws {
        let downloads = scratch.url
            .appendingPathComponent("normalizedDestination", isDirectory: true)
        let (coordinator, _, _, _, _, _) = makeCoordinator(downloadsDirectory: downloads)

        // Traversal out of Downloads, the directory itself spelled two ways,
        // and a path that was never in Downloads at all.
        let persistedSpellings = [
            downloads.appendingPathComponent("../../evil.ipsw"),
            downloads.appendingPathComponent("sub/../evil.ipsw"),
            downloads,
            downloads.appendingPathComponent(""),
            URL(fileURLWithPath: "/Users/Shared/RestoreImage.ipsw"),
        ]
        // A remote URL is no safer: it comes out of the same `config.json`.
        // The last names nothing at all, which appended verbatim resolves to
        // the Downloads directory itself.
        let traversal = try #require(URL(string: "https://host/a%2F..%2F..%2Fevil.ipsw"))
        let pathless = try #require(URL(string: "https://example.com"))
        let remoteSpellings = [traversal, pathless]

        for persisted in persistedSpellings {
            for remote in remoteSpellings {
                let normalized = coordinator.normalizedDownloadDestination(
                    for: persisted, remoteURL: remote)
                let context =
                    "persisted '\(persisted.path(percentEncoded: false))', remote '\(remote.absoluteString)'"
                #expect(
                    canonicalPath(normalized.deletingLastPathComponent())
                        == canonicalPath(downloads), "escaped Downloads for \(context)")
                #expect(
                    canonicalPath(normalized) != canonicalPath(downloads),
                    "named Downloads itself for \(context)")
                #expect(normalized.pathExtension.lowercased() == "ipsw", "not an IPSW for \(context)")
            }
        }
    }

    /// A path with `..` collapsed and any trailing separator dropped, so a
    /// directory and the same directory named as a parent compare equal.
    private func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
