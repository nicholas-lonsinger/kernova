import AppKit
import Foundation
import Testing

@testable import Kernova

@Suite("GuestSetupDescriptor Tests")
@MainActor
struct GuestSetupDescriptorTests {
    // MARK: - macOS install

    @Test("The macOS install keeps its own title and icon")
    func macOSChrome() {
        let descriptor = GuestSetupDescriptor.macOSInstall
        #expect(descriptor.title == "Installing macOS")
        #expect(descriptor.icon == .named(NSImage.computerName))
    }

    @Test("The macOS install's cancel copy says what a cancel costs at each step")
    func macOSCancelCopy() {
        let download = GuestSetupDescriptor.macOSInstall.copy(for: .download).cancelPrompt
        #expect(download.title == "Cancel Download?")
        #expect(
            download.message
                == "The download progress will be saved and resumed the next time you start the virtual machine."
        )
        #expect(download.confirmTitle == "Cancel Download")
        #expect(download.dismissTitle == "Keep Downloading")

        let install = GuestSetupDescriptor.macOSInstall.copy(for: .install).cancelPrompt
        #expect(install.title == "Cancel Installation?")
        #expect(
            install.message
                == "The installation will restart from the beginning the next time you start the virtual machine. The downloaded macOS image is cached, so you won't need to download it again."
        )
        #expect(install.confirmTitle == "Cancel Installation")
        #expect(install.dismissTitle == "Keep Installing")
    }

    @Test("The macOS install's subtitle verbs name each step's work")
    func macOSDetailVerbs() {
        #expect(GuestSetupDescriptor.macOSInstall.copy(for: .download).detailVerb == "Downloading")
        #expect(
            GuestSetupDescriptor.macOSInstall.copy(for: .install).detailVerb == "Installing macOS")
    }

    // MARK: - Linux image

    @Test("A Linux image names the distribution it is fetching")
    func linuxChrome() {
        let descriptor = GuestSetupDescriptor.linuxImage(
            distribution: "Ubuntu Desktop", version: "26.04 LTS")

        #expect(descriptor.title == "Downloading Ubuntu Desktop 26.04 LTS")
        #expect(descriptor.icon == .symbol("opticaldisc"))
        #expect(descriptor.copy(for: .download).detailVerb == "Downloading")
        #expect(descriptor.copy(for: .verify).detailVerb == "Verifying")
    }

    @Test("A cancelled Linux download keeps its partial bytes, and a cancelled check keeps the file")
    func linuxCancelCopy() {
        let descriptor = GuestSetupDescriptor.linuxImage(distribution: "Debian", version: "13")

        let download = descriptor.copy(for: .download).cancelPrompt
        #expect(download.title == "Cancel Download?")
        #expect(
            download.message
                == "The download progress will be saved and resumed the next time you start the virtual machine."
        )

        let verify = descriptor.copy(for: .verify).cancelPrompt
        #expect(verify.title == "Cancel Verification?")
        #expect(
            verify.message
                == "The downloaded image is kept, and it will be checked again the next time you start the virtual machine."
        )
        #expect(verify.confirmTitle == "Cancel Verification")
        #expect(verify.dismissTitle == "Keep Verifying")
    }

    // MARK: - Selection

    @Test("The descriptor follows whichever setup the VM has pending")
    func descriptorFollowsTheContext() {
        let linux = VMInstance(
            configuration: {
                var config = VMConfiguration(name: "Debian", guestOS: .linux, bootMode: .efi)
                config.linuxInstallContext = LinuxImageDownloadContext(
                    entry: makeLinuxCatalogEntry(distribution: "Debian", version: "13"))
                return config
            }(),
            bundleURL: FileManager.default.temporaryDirectory.appendingPathComponent("linux"))
        let macOS = VMInstance(
            configuration: {
                var config = VMConfiguration(name: "Sequoia", guestOS: .macOS, bootMode: .macOS)
                config.installContext = MacOSInstallContext(source: .downloadLatest)
                return config
            }(),
            bundleURL: FileManager.default.temporaryDirectory.appendingPathComponent("macos"))

        #expect(GuestSetupDescriptor.forSetup(of: linux).title == "Downloading Debian 13")
        #expect(GuestSetupDescriptor.forSetup(of: macOS).title == "Installing macOS")
    }

    // MARK: - Steps and copy agree

    @Test("Every step each flow runs has copy of its own")
    func everyStepHasCopy() {
        // A missing entry only shows up as a `fault` at runtime, so the pairing
        // is asserted here instead.
        for step in GuestSetupState.macOSInstall(hasDownloadStep: true).steps {
            #expect(GuestSetupDescriptor.macOSInstall.stepCopy[step.id] != nil)
        }
        let linux = GuestSetupDescriptor.linuxImage(distribution: "Debian", version: "13")
        for step in GuestSetupState.linuxImage().steps {
            #expect(linux.stepCopy[step.id] != nil)
        }
    }
}
