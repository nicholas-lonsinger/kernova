import Foundation
import Testing
import Virtualization

@testable import Kernova

/// The guest-account capability's three answers — whether to offer it, whether
/// a guest can act on it, and what Virtualization made of an account — plus the
/// redaction that keeps the password out of a description.
///
/// Nothing here asserts what Virtualization *accepts*: the framework publishes
/// no username or password rule, so a test pinning one would be inventing it.
/// What is asserted is the mapping — which field a refusal belongs to, that the
/// reason the framework wrote for the person typing survives to the surface
/// that shows it, and what stands in when it wrote none.
@Suite("macOS Guest Provisioning", .admissionGated)
struct MacOSGuestProvisioningTests {
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

    private func makeConfiguration(
        guestOS: VMGuestOS = .macOS, installedImage: InstalledImage? = nil
    ) -> VMConfiguration {
        var config = VMConfiguration(
            name: "Provisioning VM", guestOS: guestOS,
            bootMode: guestOS == .macOS ? .macOS : .efi)
        config.installedImage = installedImage
        return config
    }

    // MARK: - The Wizard's Offer

    @Test("An image below the guest floor offers no unattended setup")
    func belowFloorOffersNothing() {
        #expect(
            !MacOSGuestProvisioning.offersUnattendedSetup(
                forImageVersion: MacOSVersion(major: 26, minor: 4)))
    }

    @Test("An image whose version nothing read offers no unattended setup")
    func unknownVersionOffersNothing() {
        #expect(!MacOSGuestProvisioning.offersUnattendedSetup(forImageVersion: nil))
    }

    @available(macOS 27.0, *)
    @Test("An image at or above the guest floor offers unattended setup")
    func atFloorOffers() {
        #expect(
            MacOSGuestProvisioning.offersUnattendedSetup(
                forImageVersion: MacOSVersion(major: 27, minor: 0)))
        #expect(
            MacOSGuestProvisioning.offersUnattendedSetup(
                forImageVersion: MacOSVersion(major: 28, minor: 1)))
    }

    // MARK: - The Boot's Fact

    @available(macOS 27.0, *)
    @Test("A macOS guest installed at the floor can be provisioned")
    func guestAtFloorCanProvision() {
        let config = makeConfiguration(
            installedImage: .macOSRestoreImage(version: "27.0", build: "27A100"))
        #expect(MacOSGuestProvisioning.canProvision(config))
    }

    @Test("A macOS guest installed below the floor cannot be provisioned")
    func guestBelowFloorCannotProvision() {
        let config = makeConfiguration(
            installedImage: .macOSRestoreImage(version: "26.5.2", build: "25F84"))
        #expect(!MacOSGuestProvisioning.canProvision(config))
    }

    @Test("A VM with no installed-image record cannot be provisioned")
    func unknownGuestCannotProvision() {
        #expect(!MacOSGuestProvisioning.canProvision(makeConfiguration()))
    }

    @Test("A Linux guest cannot be provisioned, whatever version is recorded")
    func linuxCannotProvision() {
        let config = makeConfiguration(
            guestOS: .linux, installedImage: .macOSRestoreImage(version: "27.0", build: "27A100"))
        #expect(!MacOSGuestProvisioning.canProvision(config))
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

    @available(macOS 27.0, *)
    @Test("A VZ error that is not about an account names no field, and still carries its reason")
    func otherVZErrorIsUnknown() {
        let refusal = MacOSGuestProvisioning.refusal(
            from: makeVZError(
                code: VZError.Code.virtualMachineLimitExceeded.rawValue, reason: "Too many"))
        #expect(refusal.field == .unknown)
        #expect(refusal.message == "Too many")
    }

    @available(macOS 27.0, *)
    @Test("An error from another domain names no field, and still carries its reason")
    func foreignDomainIsUnknown() {
        let refusal = MacOSGuestProvisioning.refusal(
            from: NSError(
                domain: "test.kernova", code: 40001,
                userInfo: [NSLocalizedFailureReasonErrorKey: "Not a VZ refusal"]))
        #expect(refusal.field == .unknown)
        #expect(refusal.message == "Not a VZ refusal")
    }

    @available(macOS 27.0, *)
    @Test("A refusal with no reason states which control was turned down, naming no API")
    func aReasonlessRefusalNamesTheControl() {
        // `localizedDescription` would be the framework's developer-facing
        // framing ("Invalid username for guest provisioning.") — the wording
        // this surface exists not to show.
        for (code, field) in [
            (40001, GuestProvisioningRefusal.Field.fullName),
            (40002, .username),
            (40003, .password),
        ] {
            let refusal = MacOSGuestProvisioning.refusal(
                from: NSError(domain: VZError.errorDomain, code: code))
            #expect(refusal.field == field)
            #expect(!refusal.message.localizedCaseInsensitiveContains("provisioning"))
            #expect(!refusal.message.localizedCaseInsensitiveContains("error"))
            #expect(!refusal.message.isEmpty)
        }
    }

    @available(macOS 27.0, *)
    @Test("A refusal naming no field and carrying no reason still says the account was refused")
    func aReasonlessUnknownRefusalStillSpeaks() {
        let refusal = MacOSGuestProvisioning.refusal(
            from: NSError(domain: "test.kernova", code: 1))
        #expect(refusal.field == .unknown)
        #expect(!refusal.message.localizedCaseInsensitiveContains("provisioning"))
        #expect(!refusal.message.isEmpty)
    }

    @available(macOS 27.0, *)
    @Test("A refusal carrying a failure reason shows the reason, not the API-naming prefix")
    func failureReasonWinsOverTheDescription() {
        // How Virtualization words its own: `NSLocalizedFailure` frames the
        // refusal for a developer, `NSLocalizedFailureReason` for the person
        // typing, and `localizedDescription` runs the two together.
        let refusal = MacOSGuestProvisioning.refusal(
            from: NSError(
                domain: VZError.errorDomain, code: 40002,
                userInfo: [
                    NSLocalizedFailureErrorKey: "Invalid username for guest provisioning.",
                    NSLocalizedFailureReasonErrorKey: "Short name 'ada lovelace' is not valid",
                ]))
        #expect(refusal.field == .username)
        #expect(refusal.message == "Short name 'ada lovelace' is not valid")
    }

    // MARK: - Validation

    @available(macOS 27.0, *)
    @Test("What Virtualization refuses is worded for the user, naming no API")
    func realRefusalsNameNoAPI() throws {
        for credentials in [
            makeCredentials(password: ""), makeCredentials(fullName: ""),
            makeCredentials(username: "ada lovelace"),
        ] {
            let refusal = try #require(MacOSGuestProvisioning.validate(credentials))
            #expect(!refusal.message.localizedCaseInsensitiveContains("provisioning"))
        }
    }

    @available(macOS 27.0, *)
    @Test("A refused password surfaces as a password refusal carrying a message to show")
    func emptyPasswordSurfacesARefusal() throws {
        let refusal = try #require(MacOSGuestProvisioning.validate(makeCredentials(password: "")))
        #expect(refusal.field == .password)
        #expect(!refusal.message.isEmpty)
    }

    @available(macOS 27.0, *)
    @Test("A refused full name surfaces as a full-name refusal carrying a message to show")
    func emptyFullNameSurfacesARefusal() throws {
        let refusal = try #require(MacOSGuestProvisioning.validate(makeCredentials(fullName: "")))
        #expect(refusal.field == .fullName)
        #expect(!refusal.message.isEmpty)
    }

    // MARK: - The One Enforcement Path

    @Test("An incomplete account is refused in the words the surface asked in")
    func anIncompleteAccountIsRefusedInTheSurfacesWords() {
        // Both surfaces ask this one rule; only what an unfinished form says
        // belongs to the surface, because it is the surface that decides which
        // fields it gathers.
        for credentials in [
            makeCredentials(fullName: ""), makeCredentials(username: ""),
            makeCredentials(password: ""),
        ] {
            #expect(
                MacOSGuestProvisioning.refusal(
                    for: credentials, verifiedBy: credentials.password,
                    gathering: .wholeAccount, incomplete: "Fill it in.") == "Fill it in.")
        }
        #expect(
            MacOSGuestProvisioning.refusal(
                for: makeCredentials(), verifiedBy: "", gathering: .wholeAccount,
                incomplete: "Fill it in.") == "Fill it in.")
    }

    @available(macOS 27.0, *)
    @Test("A blank field the surface has no control for is Virtualization's to refuse, not a form's")
    func aBlankFieldTheSurfaceCannotGatherIsNotIncomplete() throws {
        // The resume prompt gathers the password alone: telling someone to fill
        // in a field it shows no editor for refuses whatever they type, forever.
        let message = try #require(
            MacOSGuestProvisioning.refusal(
                for: makeCredentials(fullName: ""), verifiedBy: "analytical-engine",
                gathering: .password, incomplete: "Enter the password to continue."))

        #expect(message != "Enter the password to continue.")
        #expect(message == MacOSGuestProvisioning.validate(makeCredentials(fullName: ""))?.message)
    }

    @Test("The password a surface does gather is still refused as unfinished when it is blank")
    func aBlankGatheredPasswordIsIncomplete() {
        #expect(
            MacOSGuestProvisioning.refusal(
                for: makeCredentials(password: ""), verifiedBy: "", gathering: .password,
                incomplete: "Enter the password to continue.")
                == "Enter the password to continue.")
        // The verification is the password's second spelling, so it is gathered
        // wherever the password is.
        #expect(
            MacOSGuestProvisioning.refusal(
                for: makeCredentials(), verifiedBy: "", gathering: .password,
                incomplete: "Enter the password to continue.")
                == "Enter the password to continue.")
    }

    @Test("A verification that doesn't match is refused before Virtualization sees it")
    func aMismatchIsRefusedFirst() {
        #expect(
            MacOSGuestProvisioning.refusal(
                for: makeCredentials(password: "analytical-engine"),
                verifiedBy: "difference-engine", gathering: .wholeAccount,
                incomplete: "Fill it in.")
                == "The passwords don\u{2019}t match.")
    }

    @available(macOS 27.0, *)
    @Test("A complete account Virtualization accepts is refused by nothing")
    func aCompleteAccountIsAccepted() {
        #expect(
            MacOSGuestProvisioning.refusal(
                for: makeCredentials(), verifiedBy: "analytical-engine",
                gathering: .wholeAccount, incomplete: "Fill it in.") == nil)
    }

    @available(macOS 27.0, *)
    @Test("An account Virtualization turns down carries the framework's own verdict through")
    func aRefusedAccountCarriesTheFrameworkVerdict() throws {
        let credentials = makeCredentials(username: "ada lovelace")
        let message = try #require(
            MacOSGuestProvisioning.refusal(
                for: credentials, verifiedBy: credentials.password, gathering: .wholeAccount,
                incomplete: "Fill it in."))

        #expect(message == MacOSGuestProvisioning.validate(credentials)?.message)
        #expect(message != "Fill it in.")
    }

    // MARK: - Redaction

    @Test("Describing credentials redacts the password and keeps the rest")
    func descriptionRedactsThePassword() {
        let description = makeCredentials(password: "correct-horse-battery-staple").description
        #expect(!description.contains("correct-horse-battery-staple"))
        #expect(description.contains("<redacted>"))
        #expect(description.contains("ada"))
    }
}
