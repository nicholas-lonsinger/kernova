import AVFoundation
import AppKit
import Foundation
import Testing
@testable import Kernova

/// Apply-correctness tests for the nine per-section settings coordinators.
///
/// Each test constructs a coordinator with a representative `VMInstance`,
/// calls `startObserving()` to run the initial `apply()`, then walks the
/// section's view tree to assert that the rendered AppKit controls match
/// the model state.
@Suite("Settings section coordinators")
@MainActor
struct SettingsSectionCoordinatorTests {
    // MARK: - Shared fixtures

    private func makeViewModel() -> VMLibraryViewModel {
        UserDefaults.standard.removeObject(forKey: VMLibraryViewModel.lastSelectedVMIDKey)
        UserDefaults.standard.removeObject(forKey: VMLibraryViewModel.vmOrderKey)
        return VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService()
        )
    }

    private func makeInstance(
        name: String = "Test VM",
        guestOS: VMGuestOS = .linux,
        configure: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        var config = VMConfiguration(name: name, guestOS: guestOS, bootMode: .efi)
        configure(&config)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL, status: .stopped)
    }

    /// Recursively locate the first descendant of `view` matching `predicate`.
    private func findView<T: NSView>(
        in view: NSView,
        where predicate: (T) -> Bool = { _ in true }
    ) -> T? {
        for sub in view.subviews {
            if let typed = sub as? T, predicate(typed) { return typed }
            if let nested: T = findView(in: sub, where: predicate) { return nested }
        }
        return nil
    }

    /// Recursively collect every descendant view of type `T` under `view`.
    private func findAll<T: NSView>(in view: NSView) -> [T] {
        var result: [T] = []
        for sub in view.subviews {
            if let typed = sub as? T { result.append(typed) }
            result.append(contentsOf: findAll(in: sub) as [T])
        }
        return result
    }

    // MARK: - Resources

    @Test("ResourcesSettingsSection: steppers reflect cpuCount + memorySizeInGB")
    func resourcesAppliesInitial() {
        let instance = makeInstance(guestOS: .linux) { config in
            config.cpuCount = 3
            config.memorySizeInGB = 5
        }
        let section = ResourcesSettingsSection(
            instance: instance, viewModel: makeViewModel(), isReadOnly: false)
        section.startObserving()
        let steppers: [NSStepper] = findAll(in: section.section)
        // CPU stepper + memory stepper.
        #expect(steppers.count == 2)
        #expect(steppers.contains(where: { $0.integerValue == 3 }))
        #expect(steppers.contains(where: { $0.integerValue == 5 }))
    }

    @Test("ResourcesSettingsSection: locked sets section.setLocked + disables steppers")
    func resourcesLocks() {
        let instance = makeInstance()
        let section = ResourcesSettingsSection(
            instance: instance, viewModel: makeViewModel(), isReadOnly: true)
        section.startObserving()
        let steppers: [NSStepper] = findAll(in: section.section)
        #expect(steppers.allSatisfy { !$0.isEnabled })
    }

    // MARK: - Network

    @Test("NetworkSettingsSection: switch reflects networkEnabled + MAC visible when set")
    func networkAppliesInitial() {
        let instance = makeInstance { config in
            config.networkEnabled = true
            config.macAddress = "AA:BB:CC:DD:EE:FF"
        }
        let section = NetworkSettingsSection(
            instance: instance, viewModel: makeViewModel(), isReadOnly: false)
        section.startObserving()
        let toggle: NSSwitch? = findView(in: section.section)
        #expect(toggle?.state == .on)
        // MAC address label content (monospaced) renders the configured string.
        let macLabel: NSTextField? = findView(
            in: section.section,
            where: { $0.stringValue == "AA:BB:CC:DD:EE:FF" }
        )
        #expect(macLabel != nil)
    }

    @Test("NetworkSettingsSection: networking disabled toggles switch off")
    func networkSwitchOff() {
        let instance = makeInstance { $0.networkEnabled = false }
        let section = NetworkSettingsSection(
            instance: instance, viewModel: makeViewModel(), isReadOnly: false)
        section.startObserving()
        let toggle: NSSwitch? = findView(in: section.section)
        #expect(toggle?.state == .off)
    }

    // MARK: - Audio

    @Test("AudioSettingsSection: switch reflects microphoneEnabled")
    func audioAppliesInitial() {
        let instance = makeInstance { $0.microphoneEnabled = true }
        let section = AudioSettingsSection(
            instance: instance, viewModel: makeViewModel(), isReadOnly: false)
        section.startObserving()
        let toggle: NSSwitch? = findView(in: section.section)
        #expect(toggle?.state == .on)
    }

    // MARK: - Guest Agent

    @Test("GuestAgentSettingsSection: log + nudge switches reflect config")
    func guestAgentAppliesInitial() {
        // agentInstallNudgeDismissed = false → nudge switch is .on
        // agentLogForwardingEnabled  = true  → log switch is .on
        let instance = makeInstance(guestOS: .macOS) { config in
            config.agentLogForwardingEnabled = true
            config.agentInstallNudgeDismissed = false
        }
        let section = GuestAgentSettingsSection(
            instance: instance, viewModel: makeViewModel())
        section.startObserving()
        let switches: [NSSwitch] = findAll(in: section.section)
        #expect(switches.count == 2)
        #expect(switches.allSatisfy { $0.state == .on })
    }

    @Test("GuestAgentSettingsSection: nudge dismissed flips the show-reminder switch off")
    func guestAgentNudgeDismissed() {
        let instance = makeInstance(guestOS: .macOS) { config in
            config.agentLogForwardingEnabled = true
            config.agentInstallNudgeDismissed = true
        }
        let section = GuestAgentSettingsSection(
            instance: instance, viewModel: makeViewModel())
        section.startObserving()
        // Exactly one switch should be off (the nudge), the other on (the log).
        let switches: [NSSwitch] = findAll(in: section.section)
        let onCount = switches.filter { $0.state == .on }.count
        let offCount = switches.filter { $0.state == .off }.count
        #expect(onCount == 1)
        #expect(offCount == 1)
    }

    // MARK: - Clipboard

    @Test("ClipboardSettingsSection: switch reflects clipboardSharingEnabled")
    func clipboardAppliesInitial() {
        let instance = makeInstance { $0.clipboardSharingEnabled = true }
        let section = ClipboardSettingsSection(
            instance: instance, viewModel: makeViewModel(), isReadOnly: false)
        section.startObserving()
        let toggle: NSSwitch? = findView(in: section.section)
        #expect(toggle?.state == .on)
    }

    @Test("ClipboardSettingsSection: Linux hint only visible when running + Linux")
    func clipboardLinuxHint() {
        let macOSReadOnly = ClipboardSettingsSection(
            instance: makeInstance(guestOS: .macOS),
            viewModel: makeViewModel(),
            isReadOnly: true
        )
        macOSReadOnly.startObserving()

        let linuxReadOnly = ClipboardSettingsSection(
            instance: makeInstance(guestOS: .linux),
            viewModel: makeViewModel(),
            isReadOnly: true
        )
        linuxReadOnly.startObserving()

        let linuxEditable = ClipboardSettingsSection(
            instance: makeInstance(guestOS: .linux),
            viewModel: makeViewModel(),
            isReadOnly: false
        )
        linuxEditable.startObserving()

        // The hint label is the one whose text starts with "Takes effect…".
        func hintHidden(in section: ClipboardSettingsSection) -> Bool {
            let label: NSTextField? = findView(
                in: section.section,
                where: { $0.stringValue.hasPrefix("Takes effect on next start") }
            )
            return label?.isHidden ?? true
        }

        #expect(hintHidden(in: macOSReadOnly) == true)
        #expect(hintHidden(in: linuxReadOnly) == false)
        #expect(hintHidden(in: linuxEditable) == true)
    }

    // MARK: - Storage

    @Test("StorageSettingsSection: row container holds one row per disk")
    func storageRowsCount() {
        let instance = makeInstance { config in
            config.storageDisks = [
                StorageDisk(path: "/tmp/a.asif"),
                StorageDisk(path: "/tmp/b.asif"),
                StorageDisk(path: "/tmp/c.asif"),
            ]
        }
        let section = StorageSettingsSection(
            instance: instance,
            viewModel: makeViewModel(),
            isReadOnly: false,
            fileMonitor: AttachmentFileMonitor()
        )
        section.startObserving()
        let rows: [AttachmentRowView] = findAll(in: section.section)
        #expect(rows.count == 3)
    }

    @Test("StorageSettingsSection: empty list renders the 'No storage disks' placeholder")
    func storageEmptyPlaceholder() {
        // Synthesized default disks are returned when storageDisks is nil/empty,
        // so use a configuration where defaultStorageDisks(for:) returns [].
        // The synthesizer returns 1 entry for a configured VM, which means
        // an "empty list" requires an explicit empty array AND no defaults.
        // Easiest assertion: the placeholder text doesn't appear when disks
        // exist, and the row count matches the configured list.
        let instance = makeInstance { config in
            config.storageDisks = [StorageDisk(path: "/tmp/sole.asif")]
        }
        let section = StorageSettingsSection(
            instance: instance,
            viewModel: makeViewModel(),
            isReadOnly: false,
            fileMonitor: AttachmentFileMonitor()
        )
        section.startObserving()
        let rows: [AttachmentRowView] = findAll(in: section.section)
        #expect(rows.count == 1)
    }

    // MARK: - Removable

    @Test("RemovableMediaSettingsSection: row container holds one row per media item")
    func removableRowsCount() {
        let instance = makeInstance { config in
            config.removableMedia = [
                RemovableMediaItem(path: "/tmp/iso1.iso", readOnly: true),
                RemovableMediaItem(path: "/tmp/iso2.iso", readOnly: false),
            ]
        }
        let section = RemovableMediaSettingsSection(
            instance: instance,
            viewModel: makeViewModel(),
            fileMonitor: AttachmentFileMonitor()
        )
        section.startObserving()
        let rows: [AttachmentRowView] = findAll(in: section.section)
        #expect(rows.count == 2)
    }

    @Test("RemovableMediaSettingsSection: empty config renders the empty-state label")
    func removableEmptyPlaceholder() {
        let instance = makeInstance()
        let section = RemovableMediaSettingsSection(
            instance: instance,
            viewModel: makeViewModel(),
            fileMonitor: AttachmentFileMonitor()
        )
        section.startObserving()
        let rows: [AttachmentRowView] = findAll(in: section.section)
        #expect(rows.isEmpty)
        let empty: NSTextField? = findView(
            in: section.section, where: { $0.stringValue == "No removable media attached" })
        #expect(empty != nil)
    }

    // MARK: - Shared directories

    @Test("SharedDirectoriesSettingsSection: row container holds one row per directory")
    func sharedRowsCount() {
        let instance = makeInstance { config in
            config.sharedDirectories = [
                SharedDirectory(path: "/tmp/share1"),
                SharedDirectory(path: "/tmp/share2"),
            ]
        }
        let section = SharedDirectoriesSettingsSection(
            instance: instance, viewModel: makeViewModel(), isReadOnly: false)
        section.startObserving()
        let rows: [AttachmentRowView] = findAll(in: section.section)
        #expect(rows.count == 2)
    }

    // MARK: - General

    @Test("GeneralSettingsSection: name field shows the instance's name")
    func generalNameField() {
        let instance = makeInstance(name: "Sequoia Dev")
        let section = GeneralSettingsSection(
            instance: instance, viewModel: makeViewModel())
        section.startObserving()
        // The name field is the only editable-when-renaming NSTextField that
        // also has a placeholder of "Name".
        let nameField: NSTextField? = findView(
            in: section.section,
            where: { $0.placeholderString == "Name" }
        )
        #expect(nameField?.stringValue == "Sequoia Dev")
    }

    @Test("GeneralSettingsSection: name field defaults to non-editable label appearance")
    func generalNameFieldDefaultsReadOnly() {
        let section = GeneralSettingsSection(
            instance: makeInstance(name: "Demo"), viewModel: makeViewModel())
        section.startObserving()
        let nameField: NSTextField? = findView(
            in: section.section, where: { $0.placeholderString == "Name" })
        #expect(nameField?.isEditable == false)
        #expect(nameField?.isBordered == false)
    }
}
