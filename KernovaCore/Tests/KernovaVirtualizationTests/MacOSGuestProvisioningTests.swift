import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing
import Virtualization

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaVirtualization
@testable import KernovaVirtualizationTestSupport

/// The guest-account capability's three answers — whether to offer it, whether
/// a guest can act on it, and what Virtualization made of an account — plus the
/// redaction that keeps the password out of a description.
///
/// Nothing here asserts what Virtualization *accepts*: the framework publishes
/// no username or password rule, so a test pinning one would be inventing it.
/// What is asserted is the mapping — which field a refusal belongs to, that the
/// reason the framework wrote for the person typing survives to the surface
/// that shows it, and what stands in when it wrote none.
@Suite("macOS Guest Provisioning", .caseScoped)
struct MacOSGuestProvisioningTests {
    private func makeCredentials(
        fullName: String,
        logsInAutomatically: Bool = false,
        enablesRemoteLogin: Bool = false
    ) -> GuestProvisioningCredentials {
        GuestProvisioningCredentials(
            fullName: fullName, username: "ada", password: "analytical-engine",
            logsInAutomatically: logsInAutomatically, enablesRemoteLogin: enablesRemoteLogin)
    }

    private func makeConfiguration(installedImage: InstalledImage) -> VMConfiguration {
        var config = VMConfiguration(
            name: "Provisioning VM",
            guestOS: .macOS,
            bootMode: .macOS,
            cpuCount: VMGuestOS.macOS.hostCPUCount,
            memorySizeInGB: VMGuestOS.macOS.hostMemorySize)
        config.installedImage = installedImage
        return config
    }

    // MARK: - The Wizard's Offer

    @Test("An image whose version nothing read offers no unattended setup")
    func unknownVersionOffersNothing() {
        #expect(!MacOSGuestProvisioning.offersUnattendedSetup(forImageVersion: nil))
    }

    // MARK: - The Boot's Fact

    @available(macOS 27.0, *)
    @Test("A macOS guest installed at the floor can be provisioned")
    func guestAtFloorCanProvision() {
        let config = makeConfiguration(
            installedImage: .macOSRestoreImage(version: "27.0", build: "27A100"))
        #expect(MacOSGuestProvisioning.canProvision(config))
    }

    // MARK: - Refusal Mapping

    /// A `VZError` carrying `code`, worded the way the framework words its own:
    /// the reason is the part written for the person typing.
    private func makeVZError(code: Int, reason: String) -> NSError {
        NSError(
            domain: VZError.errorDomain, code: code,
            userInfo: [NSLocalizedFailureReasonErrorKey: reason])
    }

    @available(macOS 27.0, *)
    @Test(
        "Each guest-provisioning error code names its own field",
        arguments: [
            (40001, GuestProvisioningRefusal.Field.fullName),
            (40002, GuestProvisioningRefusal.Field.username),
            (40003, GuestProvisioningRefusal.Field.password),
        ])
    func codeNamesItsField(code: Int, field: GuestProvisioningRefusal.Field) {
        let refusal = MacOSGuestProvisioning.refusal(
            from: makeVZError(code: code, reason: "Apple's own wording"))
        #expect(refusal.field == field)
        #expect(refusal.message == "Apple's own wording")
    }

    // MARK: - The One Enforcement Path

    @available(macOS 27.0, *)
    @Test("A blank field the surface has no control for is Virtualization's to refuse, not a form's")
    func aBlankFieldTheSurfaceCannotGatherIsNotIncomplete() throws {
        // The resume prompt gathers the password alone: telling someone to fill
        // in a field it shows no editor for refuses whatever they type, forever.
        let message = try #require(
            MacOSGuestProvisioning.refusal(
                for: makeCredentials(fullName: ""),
                verifiedBy: "analytical-engine",
                gathering: .password,
                incomplete: "Enter the password to continue.",
                host: VirtualizationHost()))

        #expect(message != "Enter the password to continue.")
        #expect(message == MacOSGuestProvisioning.validate(makeCredentials(fullName: ""))?.message)
    }
}
