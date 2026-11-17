import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing
import Virtualization

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaVirtualization

/// The one-shot start options a macOS boot carries: a recovery boot, an armed
/// guest account, and the exclusion between them.
@Suite("macOS Guest Start Options", .caseScoped)
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

    // MARK: - Guest Account

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
