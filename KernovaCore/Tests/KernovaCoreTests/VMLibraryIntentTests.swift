import AppIntents
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The library half of the App Intents surface: clone, rename, delete, and the
/// two cancels — what each does to the library, and how narrowly the delete is
/// offered.
///
/// Driven through the gateway rather than through the intents, which resolve
/// their `@Dependency` only inside a live intent session.
@Suite("VM Library Intent Tests", .caseScoped)
@MainActor
struct VMLibraryIntentTests {
    private let scratch = TestScratchDirectory(prefix: "VMLibraryIntentTests")

    private func makeGateway(_ wired: WiredCommandCore) -> VMIntentGateway {
        VMIntentGateway(
            commands: wired.core, readiness: LibraryReadiness(awaitReady: {}),
            index: MockVMEntityIndex(), record: makeTestIndexRecord())
    }

    /// A VM in `wired` whose guest setup is parked mid-install, so a cancel of
    /// it is offered; `cancelled` fires when the setup is cancelled.
    private func registerInstalling(
        in wired: WiredCommandCore, name: String
    ) throws -> (instance: VMInstance, cancelled: AsyncStream<Void>) {
        let instance = wired.register(name: name, phase: .initialBoot) {
            $0.installContext = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        }
        let cancelled = AsyncStream<Void>.makeStream()
        try instance.launchParkedSetup {
            cancelled.continuation.yield(())
            cancelled.continuation.finish()
        }
        return (instance, cancelled.stream)
    }

    // MARK: - Clone Outcome

    @Test("Every clone outcome, and following the preference, is offered, named, and maps back")
    func cloneOutcomesMirrorEveryOutcome() {
        for outcome in CloneOutcome.allCases.map(Optional.some) + [nil] {
            let offered = VMCloneOutcome(outcome)
            #expect(offered.outcome == outcome)
            #expect(VMCloneOutcome.caseDisplayRepresentations[offered] != nil)
        }
    }

    // MARK: - Library Verbs

    /// The copy is held mid-write, so a clone that waited for its outcome would
    /// never return.
    @Test("A clone copies the VM it identifies, with the outcome asked, and answers the arrival in full")
    func cloneAddressesByIdentifierAndAnswersTheArrival() async throws {
        let wired = WiredCommandCore()
        let sourceIdentity = Data([1, 2, 3])
        let source = wired.register {
            $0.genericMachineIdentifierData = sourceIdentity
        }
        let twin = wired.register { $0.genericMachineIdentifierData = Data([4, 5, 6]) }
        let hold = DispatchSemaphore(value: 0)
        wired.storage.setCloneHold(hold)
        // A throw before the release below would otherwise leave the copy
        // blocked for the rest of the process; a second signal is harmless.
        defer { hold.signal() }

        let copy = try await makeGateway(wired).clone(source.id, outcome: .exactCopy)

        #expect(copy.name == "Wired Copy")
        #expect(copy.status == VMStatus.preparingWireName)
        let arrival = try #require(wired.library.arrivals.first)
        #expect(copy.id == arrival.id)
        hold.signal()
        let cloned = try #require(await arrival.settle())
        // An Exact Copy keeps the identity of the VM addressed, not its twin's.
        #expect(cloned.configuration.genericMachineIdentifierData == sourceIdentity)
        #expect(twin.configuration.genericMachineIdentifierData == Data([4, 5, 6]))
    }

    @Test("A rename and a delete address their VM by identifier, never by name")
    func renameAndDeleteAddressByIdentifier() async throws {
        let wired = WiredCommandCore()
        let renamed = wired.register()
        let twin = wired.register()
        let gateway = makeGateway(wired)

        try await gateway.rename(renamed.id, to: "  Renamed  ")

        #expect(renamed.name == "Renamed")
        #expect(twin.name == "Wired")

        try await gateway.delete(renamed.id, consent: .all)

        #expect(wired.library.instances.map(\.id) == [twin.id])
    }

    @Test("Both cancels address their VM by identifier, never by name")
    func cancelsAddressByIdentifier() async throws {
        let wired = WiredCommandCore()
        let gate = GatedStep()
        let cancelled = wired.library.beginGatedArrival(.cloning, named: "Copying", gate: gate)
        let kept = wired.library.beginGatedArrival(.cloning, named: "Copying", gate: gate)
        let (installing, setupCancelled) = try registerInstalling(in: wired, name: "Installing")
        let (installingTwin, _) = try registerInstalling(in: wired, name: "Installing")
        let gateway = makeGateway(wired)

        try await gateway.cancelPreparing(cancelled.id, consent: .all)
        try await gateway.cancelGuestSetup(installing.id, consent: .all)

        #expect(cancelled.isCancelling)
        #expect(!kept.isCancelling)
        for await _ in setupCancelled { break }
        await installing.setupOperationTask?.value
        #expect(installing.setupOperationTask == nil)
        #expect(installingTwin.setupOperationTask != nil)

        gate.release()
        #expect(await cancelled.settle() == nil)
        #expect(await kept.settle() != nil)
        try wired.core.cancelGuestSetup(.id(installingTwin.id), consent: .all)
        await installingTwin.setupOperationTask?.value
    }

    /// The core trims the name and writes nothing when none is left — the
    /// inline field commits on end-editing whether or not the text changed —
    /// so a Shortcut whose Name resolves to nothing would report success
    /// having renamed nothing.
    @Test(
        "A rename carrying nothing but whitespace for a name is refused",
        arguments: ["", "   ", "\n\t "])
    func aRenameWithoutANameIsRefused(name: String) async throws {
        let wired = WiredCommandCore()
        let vm = wired.register()

        await #expect(
            throws: CommandError.invalidArgument(
                "A name is at least one character that is not a space.")
        ) {
            try await makeGateway(wired).rename(vm.id, to: name)
        }

        #expect(vm.name == "Wired")
    }

    // MARK: - Import

    @Test("An import copies the bundle it is handed, waits for the copy, and answers the settled VM")
    func importWaitsForTheCopy() async throws {
        let wired = WiredCommandCore()
        let source = try scratch.importSource(name: "Imported").url

        let entity = try await makeGateway(wired).importVM(from: source)

        // Waited: the copy has settled into a VM by the time the import answers.
        #expect(wired.library.arrivals.isEmpty)
        let imported = try #require(wired.library.instances.first)
        #expect(wired.library.instances.count == 1)
        #expect(entity.id == imported.id)
        #expect(entity.name == "Imported")
        #expect(entity.status == "stopped")
    }

    /// A bundle whose configuration reads but with nothing on disk to copy, so
    /// the import fails in the copy.
    @Test("A copy that failed leaves the import as the copy's own failure")
    func importSurfacesTheCopysFailure() async throws {
        let wired = WiredCommandCore()
        let source = scratch.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Vanished.\(VMBundleFormat.fileExtension)", isDirectory: true)
        wired.storage.files.seed(
            VMConfiguration(
                name: "Vanished", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize),
            hostState: VMHostState(), snapshots: VMSnapshotManifest(),
            pairings: USBAccessoryPairingSet(), at: source)

        let thrown = await #expect(throws: CommandError.self) {
            _ = try await makeGateway(wired).importVM(from: source)
        }

        let failure = try #require(thrown)
        #expect(failure.alertTitle == "Couldn\u{2019}t Import \u{201C}Vanished\u{201D}")
        // Thrown to the caller that waited, and reported nowhere else.
        #expect(wired.failures.isEmpty)
        #expect(wired.library.entries.isEmpty)
    }

    @Test("A picked bundle resolves to the file it names")
    func bundleFileNamesItsFile() async throws {
        let picked = scratch.url.appendingPathComponent("Imported.kernova", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)

        let resolved = try await VMBundleFile.defaultQuery.entities(
            for: [try FileEntityIdentifier.file(url: picked)])

        #expect(resolved.map(\.name) == [picked.lastPathComponent])
    }

    // MARK: - Consent

    /// The narrowest delete the core offers: the bundle to the Trash, and
    /// nothing else. A permanent delete is a user-confirmed exception to the
    /// project's file-deletion rule, and external attachments are files this
    /// surface never showed anybody.
    @Test("A delete asks once, then trashes the bundle alone")
    func deleteConsentTrashesTheBundleAlone() async throws {
        let wired = WiredCommandCore()
        let external = scratch.url.appendingPathComponent("\(UUID().uuidString)-external.img")
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: external)
        let vm = wired.register {
            $0.storageDisks = [
                StorageDisk(
                    path: external.path(percentEncoded: false), readOnly: false, label: "External",
                    isInternal: false, kind: .virtio)
            ]
        }
        let gateway = makeGateway(wired)
        var asked: [ConfirmationPrompt] = []

        try await VMConsentPolicy.run(prompting: { asked.append($0) }) { consent in
            try await gateway.delete(vm.id, consent: consent)
        }

        #expect(asked.map(\.kind) == [.deleteVM])
        #expect(wired.library.instances.isEmpty)
        #expect(wired.storage.deleteVMBundleCallCount == 1)
        #expect(wired.storage.permanentlyDeleteVMBundleCallCount == 0)
        #expect(wired.fileSystem.trashedURLs.isEmpty)
        #expect(wired.fileSystem.removedURLs.isEmpty)
    }

    @Test("Both cancels ask once and re-issue with the consent")
    func cancelsRetryTheirVerb() async throws {
        let wired = WiredCommandCore()
        let gate = GatedStep()
        let arrival = wired.library.beginGatedArrival(.cloning, named: "Copying", gate: gate)
        let (installing, setupCancelled) = try registerInstalling(in: wired, name: "Installing")
        let gateway = makeGateway(wired)
        var asked: [ConfirmationPrompt] = []

        try await VMConsentPolicy.run(prompting: { asked.append($0) }) { consent in
            try await gateway.cancelPreparing(arrival.id, consent: consent)
        }
        try await VMConsentPolicy.run(prompting: { asked.append($0) }) { consent in
            try await gateway.cancelGuestSetup(installing.id, consent: consent)
        }

        #expect(asked.map(\.kind) == [.cancelPreparing, .cancelGuestSetup])
        #expect(arrival.isCancelling)
        for await _ in setupCancelled { break }
        gate.release()
        #expect(await arrival.settle() == nil)
        await installing.setupOperationTask?.value
    }

    // MARK: - Error Surfacing

    @Test("A refusal from the core reaches the caller unchanged")
    func refusalsPassThrough() async throws {
        let wired = WiredCommandCore()
        wired.register()
        let missing = UUID()

        await #expect(throws: CommandError.notFound(.id(missing))) {
            _ = try await makeGateway(wired).clone(missing, outcome: .newMachine)
        }

        #expect(wired.library.arrivals.isEmpty)
    }
}
