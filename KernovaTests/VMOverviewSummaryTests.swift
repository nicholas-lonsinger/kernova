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

    private func value(
        _ label: String, _ category: VMSettingsCategory, _ instance: VMInstance,
        resolved: VMOverviewResolved = VMOverviewResolved()
    ) -> String? {
        VMOverviewSummary.rows(for: category, instance: instance, resolved: resolved)
            .first { $0.label == label }?.value
    }

    // MARK: - General

    @Test("General names the guest type and how it boots")
    func generalStatesTypeAndBootMode() {
        let instance = makeInstance(guestOS: .linux)
        #expect(value("Type", .general, instance) == "Linux")
        #expect(value("Boot mode", .general, instance) == instance.configuration.bootMode.displayName)
        #expect(value("Created", .general, instance) != nil)
    }

    // MARK: - System

    @Test("System states the resources and the display size the guest boots at")
    func systemStatesResourcesAndDisplay() {
        let instance = makeInstance {
            $0.displaySizesToWindow = false
            $0.displayWidth = 2560
            $0.displayHeight = 1600
            $0.displayPPI = DisplayBootSizing.hiDPIPixelsPerInch
        }
        #expect(value("CPU cores", .system, instance) == "4")
        #expect(value("Memory", .system, instance) == "8 GB")
        // HiDPI halves the stored pixels into the "looks like" size.
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

    @Test("Input devices appear only where the picker does")
    func systemStatesInputDevicesOnlyForMacOS() {
        let instance = makeInstance()
        #expect(value("Input devices", .system, instance) == nil)
        #expect(
            value(
                "Input devices", .system, instance,
                resolved: VMOverviewResolved(inputDevicesTitle: "Automatic")) == "Automatic")
    }

    // MARK: - Storage

    @Test("Storage names the boot disk and counts what else is attached")
    func storageCountsDisksAndMedia() {
        let instance = makeInstance()
        // No explicit list: the synthesized main disk is what the pane shows.
        #expect(value("Boot disk", .storage, instance) == instance.displayedStorageDisks[0].label)
        #expect(value("Disks", .storage, instance) == "1")
        #expect(value("Removable media", .storage, instance) == "None")

        let withMedia = makeInstance {
            $0.removableMedia = [RemovableMediaItem(path: "/tmp/stick.img")]
        }
        #expect(value("Removable media", .storage, withMedia) == "1")
    }

    // MARK: - Network

    @Test("Network states the picker's mode and hides what is not yet known")
    func networkStatesModeAndOmitsUnknowns() {
        let instance = makeInstance()
        #expect(value("Mode", .network, instance) == "None")
        #expect(value("IP address", .network, instance) == nil)
        #expect(value("Port forwarding", .network, instance) == nil)

        let resolved = VMOverviewResolved(
            networkModeTitle: "Wi-Fi (en0)", ipAddress: "192.168.66.4",
            portForwardingRuleCount: 1)
        #expect(value("Mode", .network, instance, resolved: resolved) == "Wi-Fi (en0)")
        #expect(value("IP address", .network, instance, resolved: resolved) == "192.168.66.4")
        #expect(value("Port forwarding", .network, instance, resolved: resolved) == "1 rule")
        #expect(
            value(
                "Port forwarding", .network, instance,
                resolved: VMOverviewResolved(portForwardingRuleCount: 3)) == "3 rules")
    }

    // MARK: - Sharing and Snapshots

    @Test("Sharing counts the shared folders")
    func sharingCountsFolders() {
        #expect(value("Shared folders", .sharing, makeInstance()) == "None")
        let shared = makeInstance {
            $0.sharedDirectories = [SharedDirectory(path: "/tmp/share")]
        }
        #expect(value("Shared folders", .sharing, shared) == "1")
    }

    @Test("Snapshots counts them and names the newest")
    func snapshotsCountAndLatest() {
        let instance = makeInstance()
        #expect(value("Snapshots", .snapshots, instance) == "0")
        #expect(value("Latest", .snapshots, instance) == nil)

        let older = VMSnapshot(name: "Older", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = VMSnapshot(name: "Newer", createdAt: Date(timeIntervalSince1970: 1_700_003_600))
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [older, newer], currentID: newer.id)

        #expect(value("Snapshots", .snapshots, instance) == "2")
        #expect(value("Latest", .snapshots, instance)?.hasPrefix("Newer") == true)
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

    @Test("Passthrough is offered only while clipboard sharing is on")
    func passthroughToggleRidesSharing() {
        func passthrough(_ instance: VMInstance) -> VMOverviewSummary.ToggleState? {
            VMOverviewSummary.toggles(for: .sharing, instance: instance)
                .first { $0.toggle == .clipboardPassthrough }
        }
        #expect(passthrough(makeInstance())?.isEnabled == false)
        let sharing = makeInstance { $0.clipboardSharingEnabled = true }
        #expect(passthrough(sharing)?.isEnabled == true)
    }

    @Test("Drag and drop is a macOS-guest switch only")
    func dropFilesToggleIsMacOSOnly() {
        let macOS = VMOverviewSummary.toggles(for: .sharing, instance: makeInstance())
        let linux = VMOverviewSummary.toggles(
            for: .sharing, instance: makeInstance(guestOS: .linux))
        #expect(macOS.contains { $0.toggle == .dropFiles })
        #expect(!linux.contains { $0.toggle == .dropFiles })
    }
}
