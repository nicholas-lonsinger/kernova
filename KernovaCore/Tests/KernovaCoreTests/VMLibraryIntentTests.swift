import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The library half of the App Intents surface: what a rename, an import and a
/// delete do to the library, and how narrowly the delete is offered.
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

    // MARK: - Library Verbs

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

    /// A bundle whose configuration reads but with nothing on disk to copy, so
    /// the import fails in the copy.
    @Test("A copy that failed leaves the import as the copy's own failure")
    func importSurfacesTheCopysFailure() async throws {
        let wired = WiredCommandCore()
        // Seeded at the spelling the import resolves it to: the store keys
        // bundles by URL, and resolving a path that doesn't exist keeps the
        // `/private` that resolving `/var` adds.
        let source = scratch.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Vanished.\(VMBundleFormat.fileExtension)", isDirectory: true)
            .resolvingSymlinksInPath()
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
            try await gateway.delete(vm.id, permanently: false, consent: consent)
        }

        #expect(asked.map(\.kind) == [.deleteVM])
        #expect(wired.library.instances.isEmpty)
        #expect(wired.storage.deleteVMBundleCallCount == 1)
        #expect(wired.storage.permanentlyDeleteVMBundleCallCount == 0)
        #expect(wired.fileSystem.trashedURLs.isEmpty)
        #expect(wired.fileSystem.removedURLs.isEmpty)
    }
}
