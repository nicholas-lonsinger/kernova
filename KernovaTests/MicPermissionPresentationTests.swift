import AVFoundation
import Testing
@testable import Kernova

@Suite("MicPermissionPresentation Tests")
struct MicPermissionPresentationTests {
    // MARK: - Mic disabled → never any supplementary UI

    @Test("A disabled mic shows nothing regardless of permission status")
    func disabledMicShowsNothing() {
        for status in [
            AVAuthorizationStatus.notDetermined, .denied, .restricted, .authorized,
        ] {
            #expect(micPermissionPresentation(status, micEnabled: false) == .none)
        }
    }

    // MARK: - Mic enabled → status-driven

    @Test("Enabled mic maps each status to the expected warning state")
    func enabledMicMapping() {
        #expect(micPermissionPresentation(.notDetermined, micEnabled: true) == .willPrompt)
        #expect(micPermissionPresentation(.denied, micEnabled: true) == .denied)
        #expect(micPermissionPresentation(.restricted, micEnabled: true) == .denied)
        #expect(micPermissionPresentation(.authorized, micEnabled: true) == .none)
    }

    // MARK: - External attachment path derivation

    @Test("External attachment paths include external disks and removable media but exclude internal disks")
    func externalAttachmentPathDerivation() {
        var config = VMConfiguration(name: "Test", guestOS: .linux, bootMode: .efi)
        config.storageDisks = [
            StorageDisk(path: "Disk.asif", isInternal: true),
            StorageDisk(path: "/Volumes/External/data.img", isInternal: false),
        ]
        config.removableMedia = [
            RemovableMediaItem(path: "/Users/me/installer.iso")
        ]

        let paths = externalAttachmentPaths(for: config)
        #expect(paths == ["/Volumes/External/data.img", "/Users/me/installer.iso"])
    }

    @Test("External attachment paths is empty when there are no attachments")
    func externalAttachmentPathsEmpty() {
        let config = VMConfiguration(name: "Test", guestOS: .linux, bootMode: .efi)
        #expect(externalAttachmentPaths(for: config).isEmpty)
    }

    // MARK: - Guest agent section visibility

    @Test("Guest Agent section is visible only for macOS guests")
    func guestAgentVisibility() {
        #expect(isGuestAgentSectionVisible(guestOS: .macOS) == true)
        #expect(isGuestAgentSectionVisible(guestOS: .linux) == false)
    }
}
