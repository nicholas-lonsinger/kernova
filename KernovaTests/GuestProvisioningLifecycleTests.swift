import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The life of a guest account on the VM that owes it: when a start has a
/// question to ask, what retraction takes, what an install leaves behind, and
/// the drop the install owes when the guest it produced turns out unable to act
/// on the account.
@Suite("Guest Provisioning Lifecycle", .admissionGated)
@MainActor
struct GuestProvisioningLifecycleTests {
    private func makeCoordinator() -> (VMLifecycleCoordinator, MockMacOSInstallService) {
        let installService = MockMacOSInstallService()
        let coordinator = VMLifecycleCoordinator(
            virtualizationService: MockVirtualizationService(),
            installService: installService,
            ipswService: MockIPSWService(),
            removableMediaDeviceService: MockRemovableMediaDeviceService())
        return (coordinator, installService)
    }

    private func makeIntent() -> GuestAccountIntent {
        GuestAccountIntent(
            fullName: "Ada Lovelace", username: "ada", logsInAutomatically: true,
            enablesRemoteLogin: false)
    }

    private func makeInstance(
        intent: GuestAccountIntent? = nil
    ) -> VMInstance {
        var config = VMConfiguration(name: "Unattended VM", guestOS: .macOS, bootMode: .macOS)
        config.installContext = MacOSInstallContext(
            source: .localFile, localIPSWPath: "/tmp/restore.ipsw")
        config.pendingGuestAccount = intent
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL)
        // Wired as the library wires it, so a retraction reaches the
        // configuration the way it does in the app.
        instance.onUpdateConfiguration = { mutate in
            mutate(&instance.configuration)
            return true
        }
        return instance
    }

    // MARK: - Rejoining the Intent

    @Test("Rejoining an intent with a password keeps the intent's four values")
    func rejoiningKeepsTheIntent() {
        let credentials = GuestProvisioningCredentials(
            intent: makeIntent(), password: "analytical-engine")
        #expect(credentials.fullName == "Ada Lovelace")
        #expect(credentials.username == "ada")
        #expect(credentials.logsInAutomatically)
        #expect(!credentials.enablesRemoteLogin)
    }

    @Test("Credentials describe themselves without the password")
    func credentialsRedactThePassword() {
        let described = String(
            describing: GuestProvisioningCredentials(
                intent: makeIntent(), password: "analytical-engine"))
        #expect(!described.contains("analytical-engine"))
        #expect(described.contains("ada"))
    }

    @Test("An answer describes itself without the password")
    func answerRedactsThePassword() {
        #expect(!String(describing: GuestAccountAnswer.password("analytical-engine")).contains("analytical-engine"))
        #expect(String(describing: GuestAccountAnswer.skip) == "skip")
    }

    // MARK: - startAsksForGuestAccount

    @Test("A VM carrying an intent has a question, wherever the host can deliver one")
    func intentMeansAQuestion() {
        // Below the host floor there is no account to create, so there is
        // nothing to ask for — and nothing for a start to refuse over either.
        #expect(
            makeInstance(intent: makeIntent()).startAsksForGuestAccount
                == MacOSGuestProvisioning.hostSupportsProvisioning)
    }

    @Test("A VM carrying no intent has nothing to ask about")
    func noIntentMeansNoQuestion() {
        #expect(!makeInstance().startAsksForGuestAccount)
    }

    @Test("Retracting an account leaves nothing to ask about")
    func retractingLeavesNoQuestion() {
        let instance = makeInstance(intent: makeIntent())

        instance.retractGuestAccount()

        // Not "asks again": the window is gone, so the question is gone with it.
        #expect(instance.configuration.pendingGuestAccount == nil)
        #expect(!instance.startAsksForGuestAccount)
    }

    @Test("Retracting an account a VM never owed writes nothing")
    func retractingWithoutAnAccountWritesNothing() {
        let instance = makeInstance()
        var writes = 0
        instance.onUpdateConfiguration = { mutate in
            writes += 1
            mutate(&instance.configuration)
            return true
        }

        instance.retractGuestAccount()

        #expect(writes == 0)
    }

    // MARK: - What an Install Leaves Behind

    @available(macOS 27.0, *)
    @Test("A completed install keeps the account for the boot chained after it")
    func installKeepsTheAccountForTheBootAfterIt() async throws {
        let (coordinator, installService) = makeCoordinator()
        installService.installedImage = .macOSRestoreImage(version: "27.0", build: "27A100")
        let instance = makeInstance(intent: makeIntent())
        let context = try #require(instance.configuration.installContext)

        try await coordinator.installMacOS(on: instance, context: context)

        // The install is over — that context goes. The account is not: the boot
        // that delivers it has not run, so anything interrupting the two must
        // leave the next Start something to ask about.
        #expect(instance.configuration.installContext == nil)
        #expect(instance.configuration.pendingGuestAccount == makeIntent())
        #expect(instance.startAsksForGuestAccount)
    }

    // MARK: - The Post-Install Drop

    @Test("An install that produced a pre-27 guest drops the account entirely")
    func installBelowFloorDropsTheAccount() async throws {
        let (coordinator, installService) = makeCoordinator()
        installService.installedImage = .macOSRestoreImage(version: "26.5.2", build: "25F84")
        let instance = makeInstance(intent: makeIntent())
        let context = try #require(instance.configuration.installContext)

        try await coordinator.installMacOS(on: instance, context: context)

        // A persisted intent left behind would ask for an account this guest
        // can never create.
        #expect(instance.configuration.pendingGuestAccount == nil)
        #expect(!instance.startAsksForGuestAccount)
        // Dropped, never refused: the install itself landed and the VM records
        // the image it came from.
        #expect(
            instance.configuration.installedImage
                == .macOSRestoreImage(version: "26.5.2", build: "25F84"))
        #expect(instance.configuration.installContext == nil)
    }
}
