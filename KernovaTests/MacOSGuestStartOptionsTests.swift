import Testing
import Virtualization

@testable import Kernova

/// The one-shot start options a macOS boot carries: a recovery boot, an armed
/// guest account, and the exclusion between them.
@Suite("macOS Guest Start Options", .admissionGated)
@MainActor
struct MacOSGuestStartOptionsTests {
    private func makeCredentials(
        fullName: String = "Ada Lovelace",
        username: String = "ada",
        password: String = "analytical-engine",
        logsInAutomatically: Bool = false,
        enablesRemoteLogin: Bool = false
    ) -> GuestProvisioningCredentials {
        GuestProvisioningCredentials(
            fullName: fullName, username: username, password: password,
            logsInAutomatically: logsInAutomatically, enablesRemoteLogin: enablesRemoteLogin)
    }

    // MARK: - Recovery

    @Test("A macOS guest with recovery requested gets startUpFromMacOSRecovery options")
    func macOSRecoveryBuildsOptions() {
        let options = MacOSGuestProvisioning.macOSStartOptions(
            bootIntoRecovery: true, guestOS: .macOS, provisioning: nil)
        #expect(options != nil)
        #expect(options?.startUpFromMacOSRecovery == true)
    }

    @Test("A Linux guest never gets recovery options")
    func linuxGetsNoOptions() {
        #expect(
            MacOSGuestProvisioning.macOSStartOptions(
                bootIntoRecovery: true, guestOS: .linux, provisioning: nil) == nil)
    }

    @Test("A macOS guest without recovery requested gets no options (normal boot)")
    func macOSWithoutRecoveryGetsNoOptions() {
        #expect(
            MacOSGuestProvisioning.macOSStartOptions(
                bootIntoRecovery: false, guestOS: .macOS, provisioning: nil) == nil)
    }

    // MARK: - Guest Account

    @Test("A Linux guest never carries an account, whatever is armed")
    func linuxCarriesNoAccount() {
        #expect(
            MacOSGuestProvisioning.macOSStartOptions(
                bootIntoRecovery: false, guestOS: .linux, provisioning: makeCredentials()) == nil)
    }

    @available(macOS 27.0, *)
    @Test("A macOS cold boot carries the armed account onto the start options")
    func coldBootCarriesTheAccount() throws {
        let credentials = makeCredentials(
            fullName: "Grace Hopper", username: "grace", password: "nanoseconds-per-foot",
            logsInAutomatically: true, enablesRemoteLogin: true)
        let options = try #require(
            MacOSGuestProvisioning.macOSStartOptions(
                bootIntoRecovery: false, guestOS: .macOS, provisioning: credentials))

        #expect(!options.startUpFromMacOSRecovery)
        let provisioning = try #require(options.guestProvisioningOptions)
        #expect(provisioning.fullName == "Grace Hopper")
        #expect(provisioning.username == "grace")
        #expect(provisioning.password == "nanoseconds-per-foot")
        #expect(provisioning.logsInAutomatically)
        #expect(provisioning.enablesRemoteLogin)
    }

    @available(macOS 27.0, *)
    @Test("A recovery boot carries no account, leaving the post-restore boot unspent")
    func recoveryBootCarriesNoAccount() throws {
        let options = try #require(
            MacOSGuestProvisioning.macOSStartOptions(
                bootIntoRecovery: true, guestOS: .macOS, provisioning: makeCredentials()))
        #expect(options.startUpFromMacOSRecovery)
        #expect(options.guestProvisioningOptions == nil)
    }

    @available(macOS 27.0, *)
    @Test("An account Virtualization refuses boots the guest unprovisioned rather than failing")
    func refusedAccountFallsBackToAPlainBoot() {
        #expect(
            MacOSGuestProvisioning.macOSStartOptions(
                bootIntoRecovery: false, guestOS: .macOS,
                provisioning: makeCredentials(password: "")) == nil)
    }
}
