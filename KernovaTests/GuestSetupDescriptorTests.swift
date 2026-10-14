import AppKit
import Foundation
import Testing

@testable import Kernova

@Suite("GuestSetupDescriptor Tests", .caseScoped)
@MainActor
struct GuestSetupDescriptorTests {
    // MARK: - macOS install

    @Test("The macOS install keeps its own title and icon")
    func macOSChrome() {
        let descriptor = GuestSetupDescriptor.macOSInstall
        #expect(descriptor.title == "Installing macOS")
        #expect(descriptor.icon == .named(NSImage.computerName))
    }

    @Test("The macOS install's subtitle verbs name each step's work")
    func macOSDetailVerbs() {
        #expect(GuestSetupDescriptor.macOSInstall.copy(for: .download).detailVerb == "Downloading")
        #expect(
            GuestSetupDescriptor.macOSInstall.copy(for: .install).detailVerb == "Installing macOS")
    }

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

    @Test("A catalog image's Verify caption names the host serving its checksum list")
    func verifyCaptionNamesTheManifestHost() {
        let instance = VMInstanceFixture.make(name: "Debian") {
            $0.linuxInstallContext = LinuxInstallContext(
                source: .catalogEntry(
                    makeLinuxCatalogEntry(
                        manifestDirectoryURLString: "https://checksums.example/debian/")))
        }

        #expect(
            GuestSetupDescriptor.forSetup(of: instance).copy(for: .verify).caption
                == "Checking against the checksum list on checksums.example")
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

    @Test("A URL pick's setup is titled with the file it is fetching")
    func descriptorNamesAPastedImage() {
        let instance = VMInstanceFixture.make(name: "Alpine") {
            $0.linuxInstallContext = LinuxInstallContext(
                source: .customURL(
                    CustomLinuxImage(
                        url: URL(string: "https://mirror.example/alpine-3.22-aarch64.iso")!,
                        sha256: nil)))
        }

        #expect(
            GuestSetupDescriptor.forSetup(of: instance).title
                == "Downloading alpine-3.22-aarch64.iso")
    }

    // MARK: - Steps and copy agree

    @Test("Every step each flow runs has copy of its own")
    func everyStepHasCopy() {
        // A missing entry only shows up as a `fault` at runtime, so the pairing
        // is asserted here instead.
        for step in GuestSetupState.macOSInstall(hasDownloadStep: true).steps {
            #expect(GuestSetupDescriptor.macOSInstall.stepCopy[step.id] != nil)
        }
        // Every Linux step has copy whatever the source, so no pairing of a
        // state with a descriptor built from a different source can miss one.
        let linuxSteps = Set(
            [DigestSource.enteredByUser, nil].flatMap {
                GuestSetupState.linuxImage(digestSource: $0).steps.map(\.id)
            })
        for source in [DigestSource.enteredByUser, nil] {
            let linux = GuestSetupDescriptor.linuxImage(named: "Debian 13", digestSource: source)
            for step in linuxSteps {
                #expect(linux.stepCopy[step] != nil)
            }
        }
    }
}
