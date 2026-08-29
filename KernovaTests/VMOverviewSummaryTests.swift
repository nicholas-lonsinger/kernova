import Foundation
import Testing

@testable import Kernova

@Suite("VMOverviewSummary Tests")
@MainActor
struct VMOverviewSummaryTests {
    private func makeInstance(
        guestOS: VMGuestOS = .macOS, mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        var config = VMConfiguration(
            name: "Test VM", guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi,
            cpuCount: 4, memorySizeInGB: 8)
        mutate(&config)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
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
        VMOverviewSummary.note(for: .sharing, instance: instance)
    }

    // MARK: - General

    @Test("General states nothing the header or its own switches already carry")
    func generalStatesNoValueRows() {
        #expect(rows(.general, makeInstance(guestOS: .linux)).isEmpty)
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

    @Test("A display sized to the window says so instead of a resolution")
    func systemStatesMatchWindow() {
        let instance = makeInstance { $0.displaySizesToWindow = true }
        #expect(value("Display", .system, instance) == "Matches window")
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

    @Test("Storage names the boot disk with its size and folds the rest into one line")
    func storageStatesBootDiskAndTheRest() {
        let instance = makeInstance()
        // No explicit list: the synthesized main disk is what the pane shows.
        let boot = instance.displayedStorageDisks[0].label
        #expect(rows(.storage, instance).map(\.label) == ["Boot disk", "Other"])
        // The capacity read hasn't landed, so the row states the label alone.
        #expect(value("Boot disk", .storage, instance) == boot)
        #expect(value("Other", .storage, instance) == "No other disks · No media")

        let sized = VMOverviewResolved(bootDiskBytes: 64_000_000_000)
        #expect(
            value("Boot disk", .storage, instance, resolved: sized)
                == "\(boot) · \(DataFormatters.formatBytes(64_000_000_000))")
    }

    @Test("The Other line counts the disks past the boot disk and the media beside them")
    func storageCountsOtherDisksAndMedia() {
        let one = makeInstance {
            $0.storageDisks = [
                StorageDisk(path: "Disk.asif", isInternal: true),
                StorageDisk(path: "/tmp/extra.asif"),
            ]
            $0.removableMedia = [RemovableMediaItem(path: "/tmp/stick.img")]
        }
        #expect(value("Other", .storage, one) == "1 more disk · 1 medium")

        let many = makeInstance {
            $0.storageDisks = [
                StorageDisk(path: "Disk.asif", isInternal: true),
                StorageDisk(path: "/tmp/extra.asif"),
                StorageDisk(path: "/tmp/third.asif"),
            ]
            $0.removableMedia = [
                RemovableMediaItem(path: "/tmp/stick.img"),
                RemovableMediaItem(path: "/tmp/installer.iso"),
            ]
        }
        #expect(value("Other", .storage, many) == "2 more disks · 2 media")
    }

    // MARK: - Network

    @Test("Network folds the mode and the address into one row, copy button and all")
    func networkFoldsModeAndAddress() {
        let instance = makeInstance()
        let resolved = VMOverviewResolved(
            networkModeTitle: "Shared Network", ipAddress: .reserved("192.168.66.4"),
            portForwardingRuleCount: 1)
        let row = rows(.network, instance, resolved: resolved).first
        #expect(row?.label == "Shared Network")
        #expect(row?.value == "192.168.66.4")
        #expect(row?.copy == VMOverviewSummary.RowCopy(value: "192.168.66.4", name: "Copy IP Address"))
        #expect(value("Port forwarding", .network, instance, resolved: resolved) == "1 rule")
        #expect(
            value(
                "Port forwarding", .network, instance,
                resolved: VMOverviewResolved(
                    networkModeTitle: "Shared Network", portForwardingRuleCount: 3)) == "3 rules")
    }

    @Test("With no address yet the mode row stands alone, offering nothing to copy")
    func networkRowOffersNoCopyWithoutAnAddress() {
        let instance = makeInstance()
        let resolved = VMOverviewResolved(networkModeTitle: "Wi-Fi (en0)")
        let row = rows(.network, instance, resolved: resolved).first
        #expect(row?.label == "Wi-Fi (en0)")
        #expect(row?.value == "")
        #expect(row?.copy == nil)
    }

    @Test("A VM with networking off states one Mode row and nothing else")
    func networkOffStatesOneRow() {
        let off = makeInstance { $0.networkEnabled = false }
        #expect(
            rows(
                .network, off,
                resolved: VMOverviewResolved(
                    networkModeTitle: "None", ipAddress: .reserved("192.168.66.4")))
                == [VMOverviewSummary.Row(label: "Mode", value: "None")])
        // Nothing resolved yet reads the same way.
        #expect(rows(.network, makeInstance()) == [VMOverviewSummary.Row(label: "Mode", value: "None")])
    }

    // MARK: - Sharing and Snapshots

    @Test("Sharing states its facts in the closing line, not in key-value rows")
    func sharingStatesNoValueRows() {
        #expect(rows(.sharing, makeInstance()).isEmpty)
    }

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
    }

    @Test("Passthrough reads off while clipboard sharing isn't carrying it")
    func sharingNoteStatesTheRunningPassthrough() {
        // Sharing turned off leaves the stored flag set, and nothing passes
        // through — the line states what is running, not what is stored.
        let stranded = makeInstance {
            $0.clipboardSharingEnabled = false
            $0.clipboardPassthroughEnabled = true
        }
        #expect(sharingNote(stranded) == "Passthrough off \u{00B7} No shared folders")

        let running = makeInstance {
            $0.clipboardSharingEnabled = true
            $0.clipboardPassthroughEnabled = true
        }
        #expect(sharingNote(running) == "Passthrough on \u{00B7} No shared folders")
    }

    @Test("Sharing is the only card closing with a line")
    func onlySharingCarriesANote() {
        let instance = makeInstance()
        for category in VMSettingsCategory.allCases {
            let note = VMOverviewSummary.note(for: category, instance: instance)
            #expect((note != nil) == (category == .sharing))
        }
    }

    @Test("Snapshots states only the newest in its body")
    func snapshotsStateTheLatestOnly() {
        let instance = makeInstance()
        #expect(rows(.snapshots, instance).isEmpty)

        let older = VMSnapshot(name: "Older", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = VMSnapshot(name: "Newer", createdAt: Date(timeIntervalSince1970: 1_700_003_600))
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [older, newer], currentID: newer.id)

        #expect(rows(.snapshots, instance).map(\.label) == ["Latest"])
        #expect(value("Latest", .snapshots, instance)?.hasPrefix("Newer") == true)
    }

    // MARK: - Header summary

    @Test("The Snapshots header counts them and states what they occupy")
    func snapshotHeaderSummaryCountsAndSizes() {
        let instance = makeInstance()
        func summary(_ resolved: VMOverviewResolved = VMOverviewResolved()) -> String? {
            VMOverviewSummary.headerSummary(
                for: .snapshots, instance: instance, resolved: resolved)
        }
        #expect(summary() == nil)

        let one = VMSnapshot(name: "Base")
        let two = VMSnapshot(name: "Later")
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [one, two], currentID: two.id)

        // The size read lands after the count, so the count stands on its own
        // until it does.
        #expect(summary() == "2")
        #expect(
            summary(VMOverviewResolved(snapshotTotalBytes: 3_000_000_000))
                == "2 \u{00B7} \(DataFormatters.formatBytes(3_000_000_000))")
    }

    @Test("Only Snapshots states a header summary")
    func onlySnapshotsCarryAHeaderSummary() {
        let instance = makeInstance()
        let snapshot = VMSnapshot(name: "Base")
        instance.snapshotManifest = VMSnapshotManifest(
            snapshots: [snapshot], currentID: snapshot.id)
        for category in VMSettingsCategory.allCases {
            let summary = VMOverviewSummary.headerSummary(
                for: category, instance: instance, resolved: VMOverviewResolved())
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

    // MARK: - Lock hints

    @Test("A card's lock claim is scoped to the rows that actually lock")
    func lockHintsAreScopedPerCategory() {
        #expect(VMSettingsCategory.general.lockHint == nil)
        #expect(VMSettingsCategory.snapshots.lockHint == nil)
        #expect(VMSettingsCategory.system.lockHint == "Most editable when stopped")
        #expect(VMSettingsCategory.network.lockHint == "Most editable when stopped")
        #expect(VMSettingsCategory.storage.lockHint == "Disks editable when stopped")
        #expect(VMSettingsCategory.sharing.lockHint == "Folders editable when stopped")
    }

    // MARK: - Toggles

    @Test("Only General and Sharing carry live switches")
    func togglesBelongToTwoCategories() {
        let instance = makeInstance()
        for category in VMSettingsCategory.allCases {
            let toggles = VMOverviewSummary.toggles(for: category, instance: instance)
            #expect(toggles.isEmpty == ![.general, .sharing].contains(category))
        }
    }

    @Test("Ephemeral Mode is offerable only with a snapshot to fall back to")
    func ephemeralToggleNeedsASnapshot() {
        let instance = makeInstance()
        func ephemeral(_ instance: VMInstance) -> VMOverviewSummary.ToggleState? {
            VMOverviewSummary.toggles(for: .general, instance: instance)
                .first { $0.toggle == .ephemeralMode }
        }
        #expect(ephemeral(instance)?.isEnabled == false)

        let snapshot = VMSnapshot(name: "Base")
        instance.snapshotManifest = VMSnapshotManifest(
            snapshots: [snapshot], currentID: snapshot.id)
        #expect(ephemeral(instance)?.isEnabled == true)

        // A VM already in the mode can always be taken back out of it.
        let stuck = makeInstance { $0.applyEphemeralMode(enabled: true, baseline: nil) }
        #expect(ephemeral(stuck)?.isEnabled == true)
        #expect(ephemeral(stuck)?.isOn == true)
    }

    @Test("Passthrough is a panel setting, never a card switch")
    func passthroughIsNotACardSwitch() {
        for instance in [makeInstance(), makeInstance { $0.clipboardSharingEnabled = true }] {
            let toggles = VMOverviewSummary.toggles(for: .sharing, instance: instance)
            #expect(!toggles.contains { $0.toggle == .clipboardPassthrough })
        }
    }

    @Test("Drag and drop is a macOS-guest switch only")
    func dropFilesToggleIsMacOSOnly() {
        let macOS = VMOverviewSummary.toggles(for: .sharing, instance: makeInstance())
        let linux = VMOverviewSummary.toggles(
            for: .sharing, instance: makeInstance(guestOS: .linux))
        #expect(macOS.map(\.toggle) == [.clipboardSharing, .dropFiles])
        #expect(linux.map(\.toggle) == [.clipboardSharing])
    }
}
