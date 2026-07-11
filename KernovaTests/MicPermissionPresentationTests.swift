import AVFoundation
import Testing
@testable import Kernova

@Suite("MicPermissionPresentation Tests")
struct MicPermissionPresentationTests {
    // MARK: - Audio input disabled → never any supplementary UI

    @Test("Disabled audio input shows nothing regardless of permission status")
    func disabledAudioInputShowsNothing() {
        for status in [
            AVAuthorizationStatus.notDetermined, .denied, .restricted, .authorized,
        ] {
            #expect(micPermissionPresentation(status, audioInputEnabled: false) == .none)
        }
    }

    // MARK: - Audio input enabled → status-driven

    @Test("Enabled audio input maps each status to the expected warning state")
    func enabledAudioInputMapping() {
        #expect(micPermissionPresentation(.notDetermined, audioInputEnabled: true) == .willPrompt)
        #expect(micPermissionPresentation(.denied, audioInputEnabled: true) == .denied)
        #expect(micPermissionPresentation(.restricted, audioInputEnabled: true) == .denied)
        #expect(micPermissionPresentation(.authorized, audioInputEnabled: true) == .none)
    }

    // MARK: - External attachment ref derivation

    @Test("External attachment refs include external disks and removable media but exclude internal disks")
    func externalAttachmentRefDerivation() {
        var config = VMConfiguration(name: "Test", guestOS: .linux, bootMode: .efi)
        let diskBookmark = Data([0xAA])
        config.storageDisks = [
            StorageDisk(path: "Disk.asif", isInternal: true),
            StorageDisk(path: "/Volumes/External/data.img", isInternal: false, bookmark: diskBookmark),
        ]
        config.removableMedia = [
            RemovableMediaItem(path: "/Users/me/installer.iso")
        ]

        let refs = externalAttachmentRefs(for: config)
        #expect(Set(refs.keys) == ["/Volumes/External/data.img", "/Users/me/installer.iso"])
        #expect(refs["/Volumes/External/data.img"] == diskBookmark)
        #expect(refs["/Users/me/installer.iso"] == Data?.none)
    }

    @Test("A non-nil bookmark wins when the same path appears on both lists")
    func externalAttachmentRefsPreferNonNilBookmark() {
        var config = VMConfiguration(name: "Test", guestOS: .linux, bootMode: .efi)
        let bookmark = Data([0xBB])
        config.storageDisks = [
            StorageDisk(path: "/Users/me/shared.iso", isInternal: false)
        ]
        config.removableMedia = [
            RemovableMediaItem(path: "/Users/me/shared.iso", bookmark: bookmark)
        ]

        let refs = externalAttachmentRefs(for: config)
        #expect(refs["/Users/me/shared.iso"] == bookmark)
    }

    @Test("External attachment refs is empty when there are no attachments")
    func externalAttachmentRefsEmpty() {
        let config = VMConfiguration(name: "Test", guestOS: .linux, bootMode: .efi)
        #expect(externalAttachmentRefs(for: config).isEmpty)
    }

    // MARK: - Guest agent section visibility

    @Test("Guest Agent section is visible only for macOS guests")
    func guestAgentVisibility() {
        #expect(isGuestAgentSectionVisible(guestOS: .macOS) == true)
        #expect(isGuestAgentSectionVisible(guestOS: .linux) == false)
    }
}
