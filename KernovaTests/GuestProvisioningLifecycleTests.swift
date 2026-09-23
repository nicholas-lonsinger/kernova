import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The pieces of a guest account that stand on their own: the three values it is
/// made of, what each of them says about itself, and what the install leaves
/// behind for the boot chained after it.
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

    /// The instance reaches its library only weakly, so the caller keeps the
    /// library alive for as long as a configuration write has to land.
    private func makeInstance(
        intent: GuestAccountIntent? = nil
    ) -> (instance: VMInstance, library: VMLibrary) {
        let instance = VMInstanceFixture.make(name: "Unattended VM", guestOS: .macOS) {
            $0.installContext = MacOSInstallContext(
                source: .localFile, localIPSWPath: "/tmp/restore.ipsw")
            $0.pendingGuestAccount = intent
        }
        return (instance, makeWiredLibrary(holding: [instance]))
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

    // MARK: - The Held Password

    @Test("A held password describes itself without spilling itself")
    func aHeldPasswordRedactsItself() {
        let password = GuestAccountPassword("analytical-engine")

        #expect(!String(describing: password).contains("analytical-engine"))
        #expect(!String(reflecting: password).contains("analytical-engine"))
        // Readable exactly where the account is created.
        #expect(password.value == "analytical-engine")
    }

    @Test("The store answers, replaces and drops one VM's password at a time")
    func theStoreKeepsOnePasswordPerVM() {
        let store = InMemoryGuestAccountPasswordStore()
        let first = UUID()
        let second = UUID()

        #expect(store.password(for: first) == nil)

        store.set(GuestAccountPassword("first-engine"), for: first)
        store.set(GuestAccountPassword("second-engine"), for: second)
        store.set(GuestAccountPassword("replaced-engine"), for: first)

        #expect(store.password(for: first)?.value == "replaced-engine")
        #expect(store.password(for: second)?.value == "second-engine")

        store.remove(for: first)
        // Holding nothing is not a failure, so a second remove is a no-op.
        store.remove(for: first)

        #expect(store.password(for: first) == nil)
        #expect(store.password(for: second)?.value == "second-engine")
    }

    // MARK: - What an Install Leaves Behind

    @available(macOS 27.0, *)
    @Test("A completed install keeps the account for the boot chained after it")
    func installKeepsTheAccountForTheBootAfterIt() async throws {
        let (coordinator, installService) = makeCoordinator()
        installService.installedImage = .macOSRestoreImage(version: "27.0", build: "27A100")
        let (instance, library) = makeInstance(intent: makeIntent())
        defer { withExtendedLifetime(library) {} }
        let context = try #require(instance.configuration.installContext)

        try await coordinator.installMacOS(on: instance, context: context)

        // The install is over — that context goes. The account is not: the boot
        // that delivers it has not run, so anything interrupting the two must
        // leave the next Start something to ask about.
        #expect(instance.configuration.installContext == nil)
        #expect(instance.configuration.pendingGuestAccount == makeIntent())
    }

    @Test("An install below the provisioning floor records the image and leaves the drop to its caller")
    func installBelowFloorRecordsTheImage() async throws {
        let (coordinator, installService) = makeCoordinator()
        installService.installedImage = .macOSRestoreImage(version: "26.5.2", build: "25F84")
        let (instance, library) = makeInstance(intent: makeIntent())
        defer { withExtendedLifetime(library) {} }
        let context = try #require(instance.configuration.installContext)

        try await coordinator.installMacOS(on: instance, context: context)

        // The version the drop is decided from — the first authoritative reading
        // of what the guest actually is.
        #expect(
            instance.configuration.installedImage
                == .macOSRestoreImage(version: "26.5.2", build: "25F84"))
        #expect(!MacOSGuestProvisioning.canProvision(instance.configuration))
    }
}
