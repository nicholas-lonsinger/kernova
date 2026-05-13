import AVFoundation
import SwiftUI

/// Settings form for editing a stopped VM's configuration, or viewing a running VM's
/// configuration in read-only mode.
struct VMSettingsView: View {
    @Bindable var instance: VMInstance
    @Bindable var viewModel: VMLibraryViewModel
    /// When `true`, all controls are disabled and a banner explains why.
    ///
    /// Used when the
    /// user toggles the detail pane to settings while the VM is running.
    let isReadOnly: Bool

    @State private var editingName = ""
    @State private var showingMicPermissionInfo = false
    @State private var micPermission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var showingCreateDisk = false
    @State private var newDiskSizeInGB = 50
    @State private var diskToRemove: StorageDisk?
    @State private var showingRemoveDiskAlert = false
    @FocusState private var isNameFieldFocused: Bool

    private var currentMicPermission: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private func updateMicPermissionStatus() {
        micPermission = currentMicPermission
    }

    private var isRenaming: Bool {
        viewModel.activeRename == .detail(instance.id)
    }

    /// Returns a SwiftUI binding for a configuration property that routes
    /// every write through `viewModel.updateConfiguration`.
    ///
    /// Centralizing the dispatch means there is exactly one place where
    /// "config changed" side effects (persist to disk + apply live policy)
    /// fire. The view becomes a pure consumer of these bindings and no
    /// longer needs an `.onChange(of: instance.configuration)` observer.
    private func configBinding<Value: Equatable>(
        _ keyPath: WritableKeyPath<VMConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { instance.configuration[keyPath: keyPath] },
            set: { newValue in
                viewModel.updateConfiguration(of: instance) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    /// Binding for `storageDisks` that materializes the implicit default
    /// main-disk entry when the configuration's list is `nil` / empty.
    ///
    /// Writes flow through `updateConfiguration`. The first reorder /
    /// remove edit converts the implicit default into a persisted
    /// explicit list, after which the user-visible state always matches
    /// the stored data.
    private var storageDiskBinding: Binding<[StorageDisk]> {
        Binding(
            get: {
                if let disks = instance.configuration.storageDisks, !disks.isEmpty {
                    return disks
                }
                return VMLibraryViewModel.defaultStorageDisks(for: instance)
            },
            set: { newValue in
                viewModel.updateConfiguration(of: instance) { config in
                    config.storageDisks = newValue.isEmpty ? nil : newValue
                }
            }
        )
    }

    /// Binding for `removableMedia`, defaulting to empty.
    private var removableMediaBinding: Binding<[RemovableMediaItem]> {
        Binding(
            get: { instance.configuration.removableMedia ?? [] },
            set: { newValue in
                viewModel.updateConfiguration(of: instance) { config in
                    config.removableMedia = newValue.isEmpty ? nil : newValue
                }
            }
        )
    }

    /// Binding that unwraps the optional shared directories array, defaulting to empty.
    private var sharedDirectoriesBinding: Binding<[SharedDirectory]> {
        Binding(
            get: { instance.configuration.sharedDirectories ?? [] },
            set: { newValue in
                viewModel.updateConfiguration(of: instance) { config in
                    config.sharedDirectories = newValue.isEmpty ? nil : newValue
                }
            }
        )
    }

    var body: some View {
        // Banner lives outside the ScrollView so it stays pinned at the top of the
        // detail pane — keeps the "read-only" cue visible even when the form is scrolled.
        VStack(spacing: 0) {
            if isReadOnly {
                readOnlyBanner
                    .padding(.horizontal)
                    .padding(.top)
            }
            ScrollView {
                Form {
                    // RATIONALE: `.disabled(isReadOnly)` is applied per section rather
                    // than at the Form level so that informational popover triggers in
                    // `resourcesSection` and `audioSection` (which handle their own
                    // disabling per-control) remain interactive in read-only mode —
                    // SwiftUI's disabled state propagates irreversibly to descendants.
                    // `guestAgentSection`, `clipboardSection`, and
                    // `removableMediaSection` carry live-editable fields that
                    // remain interactive while the VM is running. Storage Disks
                    // is `storageDevices`-backed and therefore restart-only;
                    // Removable Media is XHCI-backed and hot-pluggable.
                    generalSection.disabled(isReadOnly)
                    resourcesSection
                    storageDiskSection.disabled(isReadOnly)
                    removableMediaSection
                    sharedDirectoriesSection.disabled(isReadOnly)
                    networkSection.disabled(isReadOnly)
                    audioSection
                    if instance.configuration.guestOS == .macOS {
                        guestAgentSection
                    }
                    clipboardSection
                }
                .formStyle(.grouped)
                .padding()
            }
        }
        .alert(
            "Remove \(diskToRemove?.label ?? "Disk")?",
            isPresented: $showingRemoveDiskAlert,
            presenting: diskToRemove
        ) { disk in
            Button("Move to Trash", role: .destructive) {
                viewModel.removeStorageDisk(disk, from: instance, trashFile: true)
                diskToRemove = nil
            }
            Button("Remove from VM") {
                viewModel.removeStorageDisk(disk, from: instance, trashFile: false)
                diskToRemove = nil
            }
            Button("Cancel", role: .cancel) {
                diskToRemove = nil
            }
        } message: { disk in
            if disk.isInternal {
                Text(
                    "The disk image is stored inside the VM bundle. Move to Trash to delete it, or Remove from VM to delist the entry while keeping the file."
                )
            } else {
                Text("This will delist the disk from the VM. The file at \(disk.path) is left alone.")
            }
        }
    }

    @ViewBuilder
    private var readOnlyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
            Text(
                "Sections marked with \(Text(Image(systemName: "lock.fill")).foregroundStyle(.orange)) are locked while the VM is running. Stop the VM to change them. Other sections can be edited live."
            )
            .font(.callout)
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        }
    }

    /// Section header that appends a lock SF Symbol when `isReadOnly` is
    /// `true`, signaling that the section's controls are locked while the
    /// VM is running.
    ///
    /// Hot-toggleable sections (Guest Agent, Clipboard) keep
    /// their plain headers so the absence of the lock is itself the signal
    /// that those sections remain editable.
    ///
    /// `LocalizedStringKey` matches SwiftUI's built-in `Section("...")`
    /// initializer behavior so passing a literal participates in the same
    /// localization lookup as the rest of the app's titles would.
    @ViewBuilder
    private func lockableHeader(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if isReadOnly {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.small)
                    .help("Locked while the VM is running")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var generalSection: some View {
        Section(header: lockableHeader("General")) {
            if isRenaming {
                TextField("Name", text: $editingName)
                    .focused($isNameFieldFocused)
                    .onSubmit {
                        viewModel.commitRename(for: instance, newName: editingName)
                    }
                    .onExitCommand {
                        viewModel.cancelRename()
                    }
            } else {
                Button {
                    viewModel.renameVM(instance)
                } label: {
                    LabeledContent("Name") {
                        Text(instance.name)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!instance.status.canRename)
            }
            LabeledContent("Type", value: instance.configuration.guestOS.displayName)
            LabeledContent("Boot Mode", value: instance.configuration.bootMode.displayName)
            LabeledContent(
                "Created", value: instance.configuration.createdAt.formatted(date: .abbreviated, time: .shortened))
        }
        .onChange(of: isRenaming) { _, renaming in
            if renaming {
                editingName = instance.name
                isNameFieldFocused = true
            }
        }
        .onChange(of: isNameFieldFocused) { _, focused in
            if !focused && isRenaming {
                viewModel.commitRename(for: instance, newName: editingName)
            }
        }
    }

    @ViewBuilder
    private var removableMediaSection: some View {
        Section("Removable Media") {
            let items = removableMediaBinding.wrappedValue

            if items.isEmpty {
                Text("No removable media attached")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(removableMediaBinding) { $item in
                    HStack {
                        Image(systemName: "opticaldisc")
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label)
                            Text(item.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Toggle("Read Only", isOn: $item.readOnly)
                            .toggleStyle(.switch)
                            .labelsHidden()
                        Text("Read Only")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(role: .destructive) {
                            removableMediaBinding.wrappedValue.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button("Attach Disc Image...") {
                browseRemovableMedia()
            }

            Text(
                "Appears as a USB drive in the guest. Hot-pluggable — changes take effect immediately while the VM is running. For boot media, use Storage Disks instead."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func browseRemovableMedia() {
        let urls = NSOpenPanel.browseDiskImages(
            message: "Select disk images to attach to the VM",
            allowsMultipleSelection: true
        )
        guard !urls.isEmpty else { return }

        var current = removableMediaBinding.wrappedValue
        let existingPaths = Set(current.map(\.path))

        for url in urls {
            let path = url.path(percentEncoded: false)
            guard !existingPaths.contains(path) else { continue }
            current.append(RemovableMediaItem(path: path, readOnly: true))
        }

        removableMediaBinding.wrappedValue = current
    }

    // MARK: - Storage Disks

    @ViewBuilder
    private var storageDiskSection: some View {
        Section(header: lockableHeader("Storage Disks")) {
            let disks = storageDiskBinding.wrappedValue

            ForEach(storageDiskBinding) { $disk in
                storageDiskRow(disk: $disk)
            }
            .onMove { source, destination in
                var current = storageDiskBinding.wrappedValue
                current.move(fromOffsets: source, toOffset: destination)
                storageDiskBinding.wrappedValue = current
            }

            HStack {
                Button("Attach External Disk...") {
                    addExternalDisk()
                }

                Button("Create New Disk...") {
                    newDiskSizeInGB = instance.configuration.guestOS == .macOS ? 100 : 50
                    showingCreateDisk = true
                }
                .popover(isPresented: $showingCreateDisk, arrowEdge: .bottom) {
                    createDiskPopover
                }
            }

            Text(
                "Position 1 boots first on EFI guests. On macOS and Linux Kernel boot, position affects guest device enumeration. Installer images (.iso, .dmg) appear as USB drives in the guest; permanent disks appear as virtio block devices, so reordering an installer doesn't change your main disk's /dev/vda letter."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if instance.configuration.guestOS == .linux {
                let virtioDisks = disks.filter { $0.kind == .virtio }
                if !virtioDisks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Find in guest:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(virtioDisks) { disk in
                            Text("/dev/disk/by-id/virtio-\(disk.blockDeviceIdentifier)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func storageDiskRow(disk: Binding<StorageDisk>) -> some View {
        HStack {
            Image(
                systemName: disk.wrappedValue.kind == .usbMassStorage
                    ? "opticaldisc" : (disk.wrappedValue.isInternal ? "internaldrive" : "externaldrive")
            )
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(disk.wrappedValue.label)
                Text(diskSubtitle(for: disk.wrappedValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Toggle("Read Only", isOn: disk.readOnly)
                .toggleStyle(.switch)
                .labelsHidden()
            Text("Read Only")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                diskToRemove = disk.wrappedValue
                showingRemoveDiskAlert = true
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }

    /// Subtitle string: disk usage stats for the main bundle disk, path or
    /// label for everything else.
    private func diskSubtitle(for disk: StorageDisk) -> String {
        if disk.isInternal && disk.path == instance.bundleLayout.diskImageURL.lastPathComponent {
            if let usage = instance.cachedDiskUsageBytes {
                return
                    "\(DataFormatters.formatBytes(usage)) (on disk) / \(DataFormatters.formatDiskSize(instance.configuration.diskSizeInGB)) (allocated)"
            }
            return "\(DataFormatters.formatDiskSize(instance.configuration.diskSizeInGB)) allocated"
        }
        if disk.isInternal {
            return "In-bundle disk image"
        }
        return disk.path
    }

    private func addExternalDisk() {
        let urls = NSOpenPanel.browseDiskImages(
            message: "Select disk images to attach to the VM",
            allowsMultipleSelection: true
        )
        guard !urls.isEmpty else { return }

        var current = storageDiskBinding.wrappedValue
        let existingPaths = Set(current.map(\.path))

        for url in urls {
            let path = url.path(percentEncoded: false)
            guard !existingPaths.contains(path) else { continue }
            current.append(StorageDisk(path: path))
        }

        storageDiskBinding.wrappedValue = current
    }

    @ViewBuilder
    private var createDiskPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create New Disk")
                .font(.headline)

            Picker("Size", selection: $newDiskSizeInGB) {
                ForEach(VMGuestOS.allDiskSizes, id: \.self) { size in
                    Text(DataFormatters.formatDiskSize(size)).tag(size)
                }
            }

            Text("Creates an ASIF sparse disk image inside the VM bundle. Physical size grows as data is written.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") {
                    showingCreateDisk = false
                }
                Spacer()
                Button("Create") {
                    showingCreateDisk = false
                    viewModel.createStorageDisk(for: instance, sizeInGB: newDiskSizeInGB)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 280)
    }

    @ViewBuilder
    private var resourcesSection: some View {
        Section(header: lockableHeader("Resources")) {
            let os = instance.configuration.guestOS

            Stepper(
                "CPU Cores: \(instance.configuration.cpuCount)",
                value: configBinding(\.cpuCount),
                in: os.minCPUCount...os.maxCPUCount
            )
            .disabled(isReadOnly)

            Stepper(
                "Memory: \(instance.configuration.memorySizeInGB) GB",
                value: configBinding(\.memorySizeInGB),
                in: os.minMemoryInGB...os.maxMemoryInGB
            )
            .disabled(isReadOnly)
        }
        .task(id: instance.id) {
            await instance.refreshDiskUsage()
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        Section(header: lockableHeader("Network")) {
            Toggle("Networking Enabled", isOn: configBinding(\.networkEnabled))
            if let mac = instance.configuration.macAddress {
                LabeledContent("MAC Address", value: mac)
            }
        }
    }

    @ViewBuilder
    private var audioSection: some View {
        Section(header: lockableHeader("Audio")) {
            Toggle("Microphone", isOn: configBinding(\.microphoneEnabled))
                .disabled(isReadOnly)
            Text("Allows the guest to access the host microphone. Speaker output is always enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Permission warning + info-popover button are left un-disabled so the
            // explanation of how to re-enable the mic in System Settings remains
            // reachable in read-only mode.
            if instance.configuration.microphoneEnabled {
                if micPermission == .notDetermined {
                    Text("macOS will ask for microphone permission the first time a VM uses it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if micPermission == .denied || micPermission == .restricted {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)

                        Text(
                            "Microphone permission is denied. Enable it in System Settings for Kernova to pass your microphone to VMs."
                        )
                        .font(.caption)

                        Spacer()

                        Button {
                            showingMicPermissionInfo.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showingMicPermissionInfo, arrowEdge: .trailing) {
                            micPermissionInfoPopover
                        }
                    }
                    .padding(10)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(0.1))
                            .strokeBorder(Color.red.opacity(0.3), lineWidth: 1)
                    }
                }
            }
        }
        .onChange(of: instance.configuration.microphoneEnabled) {
            updateMicPermissionStatus()
        }
        .onAppear {
            updateMicPermissionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updateMicPermissionStatus()
        }
    }

    @ViewBuilder
    private var guestAgentSection: some View {
        Section("Guest Agent") {
            Toggle(
                "Forward guest logs",
                isOn: configBinding(\.agentLogForwardingEnabled)
            )
            Text(
                "Streams `os.Logger` records from the macOS guest agent to the host so they appear in Console.app under `com.kernova.guest`. Off by default; can be toggled while the VM is running."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Toggle(
                "Show install reminder",
                isOn: Binding(
                    get: { !instance.configuration.agentInstallNudgeDismissed },
                    set: { newValue in
                        viewModel.updateConfiguration(of: instance) {
                            $0.agentInstallNudgeDismissed = !newValue
                        }
                    }
                )
            )
            Text(
                "Surfaces the install icon in the sidebar when the guest agent has not yet connected. Turn off to suppress the nudge for this VM. The more urgent indicators (update available, didn't reconnect, unresponsive) are not affected."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var clipboardSection: some View {
        Section("Clipboard") {
            Toggle("Clipboard Sharing", isOn: configBinding(\.clipboardSharingEnabled))
            Text(
                "Exchanges clipboard text between host and guest. macOS guests use the bundled Kernova guest agent — Kernova will offer to install or update it from the clipboard window. Linux guests need spice-vdagent installed via the guest's package manager."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if isReadOnly && instance.configuration.guestOS == .linux {
                Text("Takes effect on next start — Linux guests configure SPICE at VM start time.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var sharedDirectoriesSection: some View {
        Section(header: lockableHeader("Shared Directories")) {
            let directories = sharedDirectoriesBinding.wrappedValue

            if directories.isEmpty {
                Text("No shared directories")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sharedDirectoriesBinding) { $directory in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(directory.displayName)
                            Text(directory.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Toggle("Read Only", isOn: $directory.readOnly)
                            .toggleStyle(.switch)
                            .labelsHidden()
                        Text("Read Only")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(role: .destructive) {
                            sharedDirectoriesBinding.wrappedValue.removeAll { $0.id == directory.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button("Add Shared Directory...") {
                addSharedDirectory()
            }

            if instance.configuration.guestOS == .linux {
                Text(
                    "Shared directories are available as virtiofs mounts in the guest. Mount them with `mount -t virtiofs <tag> <mountpoint>`."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if !directories.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mount in guest:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(directories.enumerated()), id: \.element.id) { index, directory in
                            Text("mount -t virtiofs share\(index) /mnt/\(directory.displayName)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            } else {
                Text("Shared directories auto-mount at /Volumes/My Shared Files/ in the guest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !directories.isEmpty {
                Text(
                    "Note: File sharing uses VirtioFS which has known framework limitations — files may intermittently appear missing, and permission mapping between host and guest can differ."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func addSharedDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Select directories to share with the VM"
        panel.prompt = "Share"

        guard panel.runModal() == .OK else { return }

        var current = sharedDirectoriesBinding.wrappedValue
        let existingPaths = Set(current.map(\.path))

        for url in panel.urls {
            let path = url.path(percentEncoded: false)
            guard !existingPaths.contains(path) else { continue }
            current.append(SharedDirectory(path: path))
        }

        sharedDirectoriesBinding.wrappedValue = current
    }

    @ViewBuilder
    private var micPermissionInfoPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Microphone Permission")
                .font(.headline)

            Text("Kernova needs microphone permission to pass your mic input to virtual machines.")

            Divider()

            Text("How to enable")
                .font(.subheadline)
                .fontWeight(.medium)

            VStack(alignment: .leading, spacing: 4) {
                Text("1. Open **System Settings**")
                Text("2. Go to **Privacy & Security → Microphone**")
                Text("3. Enable the toggle for **Kernova**")
            }
            .font(.callout)

            Text("You will need to restart Kernova after granting permission.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 340)
    }
}
