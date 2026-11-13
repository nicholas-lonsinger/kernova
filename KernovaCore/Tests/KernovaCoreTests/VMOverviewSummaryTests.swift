import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMOverviewSummary Tests", .caseScoped)
@MainActor
struct VMOverviewSummaryTests {
    private func makeInstance(
        guestOS: VMGuestOS = .macOS, hostState: VMHostState = VMHostState(),
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        VMInstanceFixture.make(guestOS: guestOS, hostState: hostState) {
            $0.cpuCount = 4
            $0.memorySizeInGB = .gibibytes(8)
            mutate(&$0)
        }
    }

    private func rows(
        _ category: VMSettingsCategory, _ instance: VMInstance,
        resolved: VMOverviewResolved = VMOverviewResolved()
    ) -> [VMOverviewSummary.Row] {
        VMOverviewSummary.rows(for: category, instance: instance, resolved: resolved)
    }

    private func value(
        _ label: String, _ category: VMSettingsCategory, _ instance: VMInstance,
        resolved: VMOverviewResolved = VMOverviewResolved()
    ) -> String? {
        rows(category, instance, resolved: resolved).first { $0.label == label }?.value
    }

    private func sharingNote(_ instance: VMInstance) -> String? {
        VMOverviewSummary.note(for: .sharing, instance: instance, resolved: VMOverviewResolved())
    }

    /// Answers only through the VM's own activity, so any library serves.
    private let library = makeWiredLibrary()

    private func toggles(
        for category: VMSettingsCategory, instance: VMInstance
    ) -> [VMOverviewSummary.ToggleState] {
        VMOverviewSummary.toggles(
            for: category, instance: instance, capabilities: VMCapabilityCatalog(library: library))
    }

    // MARK: - System

    @Test("System states the display size and the audio streams, and nothing else")
    func systemStatesDisplayAndAudioOnly() {
        let instance = makeInstance {
            $0.displaySizesToWindow = false
            $0.displayWidth = 2560
            $0.displayHeight = 1600
            $0.displayPPI = DisplayBootSizing.hiDPIPixelsPerInch
        }
        // HiDPI halves the stored pixels into the "looks like" size. Cores and
        // memory are the header's facts line, so the card doesn't repeat them.
        #expect(rows(.system, instance).map(\.label) == ["Display", "Audio"])
        #expect(value("Display", .system, instance) == "1280 × 800")
    }

    @Test("Audio reads as the streams that are on")
    func systemStatesAudioStreams() {
        let cases: [(input: Bool, output: Bool, expected: String)] = [
            (true, true, "Input and output"),
            (true, false, "Input only"),
            (false, true, "Output only"),
            (false, false, "Off"),
        ]
        for entry in cases {
            let instance = makeInstance {
                $0.audioInputEnabled = entry.input
                $0.audioOutputEnabled = entry.output
            }
            #expect(value("Audio", .system, instance) == entry.expected)
        }
    }

    // MARK: - Storage

    @Test("Storage lists each disk by its label, empty until measured, then the media count")
    func storageListsTheSoleDiskUnmeasured() {
        let instance = makeInstance()
        // No explicit list: the synthesized main disk is what the pane shows.
        let main = instance.effectiveStorageDisks[0]
        #expect(
            rows(.storage, instance)
                == [
                    VMOverviewSummary.Row(label: main.label, value: ""),
                    VMOverviewSummary.Row(label: "Removable media", value: "None"),
                ])

        let sized = VMOverviewResolved(
            attachmentSizes: [main.id: VMBundleLayout.DiskSizes(onDiskBytes: 1, capacityBytes: 64_000_000_000)])
        #expect(value(main.label, .storage, instance, resolved: sized) == DataFormatters.formatBytes(64_000_000_000))
    }

    @Test("An installer ahead of the main disk lists first, with capacities, USB marked, none named the boot disk")
    func storageListsEveryDiskInAttachmentOrder() {
        let installer = StorageDisk(path: "/tmp/ubuntu-26.04.1-desktop-arm64.iso")
        let main = StorageDisk(path: "Disk.asif", label: "Main Disk", isInternal: true)
        let instance = makeInstance(guestOS: .linux) {
            $0.storageDisks = [installer, main]
            $0.removableMedia = [RemovableMediaItem(path: "/tmp/stick.img")]
        }
        let resolved = VMOverviewResolved(attachmentSizes: [
            installer.id: VMBundleLayout.DiskSizes(onDiskBytes: 4_150_000_000, capacityBytes: 4_150_000_000),
            main.id: VMBundleLayout.DiskSizes(onDiskBytes: 9_000_000_000, capacityBytes: 100_000_000_000),
        ])

        #expect(
            rows(.storage, instance, resolved: resolved)
                == [
                    VMOverviewSummary.Row(
                        label: "ubuntu-26.04.1-desktop-arm64",
                        value: "\(DataFormatters.formatBytes(4_150_000_000)) · USB"),
                    VMOverviewSummary.Row(label: "Main Disk", value: DataFormatters.formatBytes(100_000_000_000)),
                    VMOverviewSummary.Row(label: "Removable media", value: "1 medium"),
                ])
        #expect(!rows(.storage, instance, resolved: resolved).contains { $0.label.lowercased().contains("boot") })
    }

    @Test("A USB disk not yet measured says USB alone; one measured unreadable says Unknown")
    func storageStatesUnmeasuredAndUnreadableDisks() {
        let installer = StorageDisk(path: "/tmp/installer.iso")
        let external = StorageDisk(path: "/tmp/gone.asif")
        let instance = makeInstance { $0.storageDisks = [installer, external] }
        #expect(value(installer.label, .storage, instance) == "USB")
        #expect(value(external.label, .storage, instance) == "")

        let unreadable = VMOverviewResolved(attachmentSizes: [
            installer.id: VMBundleLayout.DiskSizes(), external.id: VMBundleLayout.DiskSizes(),
        ])
        #expect(value(installer.label, .storage, instance, resolved: unreadable) == "Unknown · USB")
        #expect(value(external.label, .storage, instance, resolved: unreadable) == "Unknown")
    }

    // MARK: - Network

    @Test("Network folds the mode and the address into one row, copy button and all")
    func networkFoldsModeAndAddress() {
        let instance = makeInstance()
        let resolved = VMOverviewResolved(
            networkModeLabel: NetworkChoiceLabel(mode: .nat, entry: "Common"), ipAddress: .observed("192.168.66.4"))
        let network = rows(.network, instance, resolved: resolved)
        #expect(network.count == 1)
        #expect(network.first?.label == "NAT \u{2013} Common")
        #expect(network.first?.value == "192.168.66.4")
        #expect(network.first?.copy == VMOverviewSummary.RowCopy(value: "192.168.66.4", name: "Copy IP Address"))
    }

    @Test("With no address yet the mode row stands alone, offering nothing to copy")
    func networkRowOffersNoCopyWithoutAnAddress() {
        let instance = makeInstance()
        let resolved = VMOverviewResolved(networkModeLabel: NetworkChoiceLabel(mode: .bridged, entry: "Wi-Fi (en0)"))
        let row = rows(.network, instance, resolved: resolved).first
        #expect(row?.label == "Bridged \u{2013} Wi-Fi (en0)")
        #expect(row?.value == "")
        #expect(row?.copy == nil)
    }

    // MARK: - Sharing and Snapshots

    @Test("Sharing's line names the passthrough state and counts the folders")
    func sharingNoteStatesPassthroughAndFolders() {
        #expect(sharingNote(makeInstance()) == "Passthrough off \u{00B7} No shared folders")

        let one = makeInstance {
            $0.clipboardSharingEnabled = true
            $0.clipboardPassthroughEnabled = true
            $0.sharedDirectories = [SharedDirectory(path: "/tmp/share")]
        }
        #expect(sharingNote(one) == "Passthrough on \u{00B7} 1 shared folder")

        let two = makeInstance {
            $0.sharedDirectories = [
                SharedDirectory(path: "/tmp/share"), SharedDirectory(path: "/tmp/other"),
            ]
        }
        #expect(sharingNote(two) == "Passthrough off \u{00B7} 2 shared folders")

        // A Linux guest has no passthrough to state, whatever its stored flags.
        let linux = makeInstance(guestOS: .linux) {
            $0.clipboardSharingEnabled = true
            $0.clipboardPassthroughEnabled = true
        }
        #expect(sharingNote(linux) == "No shared folders")
    }

    @Test("General closes with the shared machine ID note the resolver found")
    func generalCarriesTheSharedMachineIDNote() {
        var resolved = VMOverviewResolved()
        resolved.sharedMachineIDNote = "Same machine ID as \u{201C}Twin\u{201D}."
        #expect(
            VMOverviewSummary.note(for: .general, instance: makeInstance(), resolved: resolved)
                == "Same machine ID as \u{201C}Twin\u{201D}.")
    }

    @Test("Snapshots states only the newest in its body")
    func snapshotsStateTheLatestOnly() {
        let instance = makeInstance()
        #expect(rows(.snapshots, instance).isEmpty)

        let older = VMSnapshot(name: "Older", createdAt: Date(timeIntervalSince1970: 1_700_000_000), macAddress: nil)
        let newer = VMSnapshot(name: "Newer", createdAt: Date(timeIntervalSince1970: 1_700_003_600), macAddress: nil)
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [older, newer], currentID: newer.id))

        #expect(rows(.snapshots, instance).map(\.label) == ["Latest"])
        #expect(value("Latest", .snapshots, instance)?.hasPrefix("Newer") == true)
    }

    // MARK: - Header summary

    @Test("Only Snapshots states a header summary")
    func onlySnapshotsCarryAHeaderSummary() {
        let instance = makeInstance()
        let snapshot = VMSnapshot(name: "Base", macAddress: nil)
        instance.seedSnapshotManifest(
            VMSnapshotManifest(
                snapshots: [snapshot], currentID: snapshot.id))
        for category in VMSettingsCategory.allCases {
            let summary = VMOverviewSummary.headerSummary(for: category, instance: instance)
            #expect((summary != nil) == (category == .snapshots))
        }
    }

    // MARK: - Actions

    @Test("Take Snapshot is the Snapshots card's command, gated by the view model's own read")
    func snapshotsCarryTheOnlyAction() {
        for category in VMSettingsCategory.allCases {
            let action = VMOverviewSummary.action(for: category, resolved: VMOverviewResolved())
            #expect((action != nil) == (category == .snapshots))
        }
        #expect(
            VMOverviewSummary.action(for: .snapshots, resolved: VMOverviewResolved())
                == VMOverviewSummary.ActionState(action: .takeSnapshot, isEnabled: false))
        #expect(
            VMOverviewSummary.action(
                for: .snapshots, resolved: VMOverviewResolved(canTakeSnapshot: true))
                == VMOverviewSummary.ActionState(action: .takeSnapshot, isEnabled: true))
    }

    // MARK: - Toggles

    @Test("Ephemeral Mode is offerable without a snapshot only while one can be taken")
    func ephemeralToggleNeedsASnapshotOrItsCapture() {
        let instance = makeInstance()
        func ephemeral(_ instance: VMInstance) -> VMOverviewSummary.ToggleState? {
            toggles(for: .general, instance: instance)
                .first { $0.toggle == .ephemeralMode }
        }
        // A stopped VM takes the baseline as the mode turns on.
        #expect(ephemeral(instance)?.isEnabled == true)
        let settingUp = makeInstance()
        settingUp.activity.placeForTesting(.initialBoot)
        #expect(ephemeral(settingUp)?.isEnabled == false)

        let snapshot = VMSnapshot(name: "Base", macAddress: nil)
        instance.seedSnapshotManifest(
            VMSnapshotManifest(
                snapshots: [snapshot], currentID: snapshot.id))
        #expect(ephemeral(instance)?.isEnabled == true)

        // A VM already in the mode can always be taken back out of it.
        let stuck = makeInstance(hostState: VMHostState(ephemeralModeEnabled: true))
        #expect(ephemeral(stuck)?.isEnabled == true)
        #expect(ephemeral(stuck)?.isOn == true)
    }

    @Test("The Sharing card's switches are a macOS guest's: a Linux guest has none")
    func sharingTogglesAreMacOSOnly() {
        let macOS = toggles(for: .sharing, instance: makeInstance())
        let linux = toggles(
            for: .sharing, instance: makeInstance(guestOS: .linux))
        #expect(macOS.map(\.toggle) == [.clipboardSharing, .dropFiles])
        #expect(linux.isEmpty)
    }
}
