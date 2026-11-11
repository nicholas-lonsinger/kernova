import AppKit
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

@Suite("GuestSetupDescriptor Tests", .caseScoped)
@MainActor
struct GuestSetupDescriptorTests {
    // MARK: - Linux image

    @Test("A Linux image names the image it is fetching")
    func linuxChrome() {
        let descriptor = GuestSetupDescriptor.linuxImage(
            named: "Ubuntu Desktop 26.04 LTS", digestSource: .enteredByUser)

        #expect(descriptor.title == "Downloading Ubuntu Desktop 26.04 LTS")
        #expect(descriptor.icon == .symbol("opticaldisc"))
        #expect(descriptor.copy(for: .download).detailVerb == "Downloading")
        #expect(descriptor.copy(for: .download).caption == nil)
        #expect(descriptor.copy(for: .verify).detailVerb == "Verifying")
        #expect(descriptor.copy(for: .verify).caption == "Checking against the checksum you entered")
    }

    @Test("An image with no digest computes its checksum, uncaptioned")
    func checksumCopy() {
        let descriptor = GuestSetupDescriptor.linuxImage(named: "alpine.iso", digestSource: nil)

        let copy = descriptor.copy(for: .checksum)
        #expect(copy.detailVerb == "Computing checksum")
        #expect(copy.caption == nil)
        #expect(
            GuestSetupProgressViewController.detailLine1(for: .fraction(0.42), verb: copy.detailVerb)
                == "Computing checksum:\u{2007}\u{2007}42%")
    }

    // MARK: - Selection

    @Test("The descriptor follows whichever setup the VM has pending")
    func descriptorFollowsTheContext() {
        let linux = VMInstanceFixture.make(name: "Debian") {
            $0.linuxInstallContext = LinuxInstallContext(
                source: .catalogEntry(makeLinuxCatalogEntry(distribution: "Debian", version: "13")))
        }
        let macOS = VMInstanceFixture.make(name: "Sequoia", guestOS: .macOS) {
            $0.installContext = MacOSInstallContext(source: .downloadLatest)
        }

        #expect(GuestSetupDescriptor.forSetup(of: linux).title == "Downloading Debian 13")
        #expect(GuestSetupDescriptor.forSetup(of: macOS).title == "Installing macOS")
    }
}
