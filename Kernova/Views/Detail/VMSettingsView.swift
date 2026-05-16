import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var showingReorderDisksSheet = false
    @State private var showingCreateRemovableMedia = false
    @State private var newDiskSizeInGB = VMGuestOS.defaultDiskSizeInGB
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
                    // RATIONALE: Each section that locks while the VM is running wraps
                    // its locked controls in `Group { ... }.disabled(isReadOnly)` *inside*
                    // the section body. SwiftUI's `.disabled` propagates irreversibly to
                    // descendants, so this scoping keeps the section's header (lock + info
                    // button) and any always-on body content (info popovers, conditional
                    // warnings, listings) outside the disabled subtree and therefore
                    // interactive. Sections that are fully hot-toggleable (Removable
                    // Media, Guest Agent, Clipboard) carry no disable wrapper. Storage
                    // Disks is `storageDevices`-backed and therefore restart-only;
                    // Removable Media is XHCI-backed and hot-pluggable.
                    generalSection
                    resourcesSection
                    storageDiskSection
                    removableMediaSection
                    sharedDirectoriesSection
                    networkSection
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

    /// Section header that prepends a lock SF Symbol when the section is
    /// lockable and the VM is running.
    ///
    /// Hot-toggleable sections (Guest Agent, Clipboard, Removable Media)
    /// pass `lockable: false` so the absence of the lock is itself the
    /// signal that those sections remain editable.
    ///
    /// `LocalizedStringKey` matches SwiftUI's built-in `Section("...")`
    /// initializer behavior so passing a literal participates in the same
    /// localization lookup as the rest of the app's titles would.
    ///
    /// The HStack's children are intentionally **not** combined for
    /// accessibility — `InfoButton` is interactive and must remain
    /// independently focusable in VoiceOver, and `lockIcon` carries its
    /// own accessibility label so the locked state is announced.
    @ViewBuilder
    private func sectionHeader(_ title: LocalizedStringKey, lockable: Bool = false) -> some View {
        HStack(spacing: 6) {
            if lockable && isReadOnly {
                lockIcon
            }
            Text(title)
        }
    }

    /// Section header variant that also surfaces an info button at the end,
    /// revealing the per-section help text in a popover.
    @ViewBuilder
    private func sectionHeader<Info: View>(
        _ title: LocalizedStringKey,
        lockable: Bool = false,
        @ViewBuilder info: @escaping () -> Info
    ) -> some View {
        HStack(spacing: 6) {
            if lockable && isReadOnly {
                lockIcon
            }
            Text(title)
            InfoButton(label: title, content: info)
        }
    }

    @ViewBuilder
    private var lockIcon: some View {
        Image(systemName: "lock.fill")
            .foregroundStyle(.orange)
            .imageScale(.small)
            .help("Locked while the VM is running")
            .accessibilityLabel("Locked while the VM is running")
    }

    // MARK: - Sections

    @ViewBuilder
    private var generalSection: some View {
        // Name is hot-editable (same as the sidebar's right-click rename), and Type /
        // Boot Mode / Created are immutable metadata even when stopped — so the
        // section as a whole carries no lock and no `.disabled(isReadOnly)` wrapper.
        Section(header: sectionHeader("General")) {
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
        Section(
            header: sectionHeader("Removable Media") {
                VStack(alignment: .leading, spacing: 10) {
                    if instance.configuration.guestOS == .linux {
                        Text(
                            "Appears as a USB Mass Storage device (typically `/dev/sda` or similar). Most desktop distros auto-mount; headless installs need an explicit `mount`."
                        )
                    } else {
                        Text("Appears as a removable USB drive in Finder; auto-mounts.")
                    }
                    Text(
                        "Hot-pluggable — changes take effect immediately while the VM is running. For boot media, use Storage Disks instead."
                    )
                }
            }
        ) {
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

            HStack {
                Button("Attach Disc...") {
                    browseRemovableMedia()
                }

                Button("Create New Disk...") {
                    showingCreateRemovableMedia = true
                }
                .popover(isPresented: $showingCreateRemovableMedia, arrowEdge: .bottom) {
                    createRemovableMediaPopover
                }
            }
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

    /// Presents a save panel for a new removable-media disk image and dispatches
    /// the create call when the user confirms.
    ///
    /// Uses the asynchronous `begin(completionHandler:)` API so SwiftUI can
    /// finish the popover-dismissal animation before the save panel takes the
    /// foreground — `runModal()` would block the main thread and freeze the
    /// transition.
    private func presentSaveRemovableMedia(for instance: VMInstance, sizeInGB: Int) {
        let panel = NSSavePanel()
        panel.title = "Save Removable Disk"
        panel.message = "Choose where to save the new removable disk image."
        panel.prompt = "Create"
        panel.nameFieldStringValue = "\(instance.name) Removable Disk.asif"
        // Constrain to `.asif` — we only know how to allocate ASIF. NSSavePanel
        // appends the extension if the user omits it, and rejects mismatched
        // extensions since `allowsOtherFileTypes` defaults to false.
        panel.allowedContentTypes = [.asif]
        panel.canCreateDirectories = true
        // Intentionally no `directoryURL` — NSSavePanel remembers the user's
        // last-used location, which is a better default than forcing every
        // invocation back to ~/Documents.

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            viewModel.createRemovableMedia(
                for: instance, sizeInGB: sizeInGB, destinationURL: url)
        }
    }

    // MARK: - Storage Disks

    @ViewBuilder
    private var storageDiskSection: some View {
        Section(
            header: sectionHeader("Storage Disks", lockable: true) {
                VStack(alignment: .leading, spacing: 10) {
                    if instance.configuration.guestOS == .linux {
                        Text(
                            "Position 1 boots first on EFI guests; on Linux Kernel boot, position affects device enumeration but not boot priority."
                        )
                        Text("Permanent disks attach as virtio block devices (`/dev/vda`, `/dev/vdb`, …).")
                        Text(
                            "Installer images (.iso, .dmg) attach as USB Mass Storage entries on this list — still bootable, separate from hot-pluggable Removable Media — so reordering an installer doesn't change your main disk's `/dev/vda` letter."
                        )
                    } else {
                        Text("Position 1 is the main system disk; subsequent positions follow in order.")
                        Text("Permanent disks attach as virtio block devices.")
                        Text(
                            "Installer images (.iso, .dmg) attach as USB Mass Storage entries on this list — still bootable, separate from hot-pluggable Removable Media."
                        )
                    }
                }
            }
        ) {
            Group {
                ForEach(storageDiskBinding) { $disk in
                    storageDiskRow(disk: $disk)
                }

                HStack {
                    Button("Attach Disc...") {
                        addExternalDisk()
                    }

                    Button("Create New Disk...") {
                        showingCreateDisk = true
                    }
                    .popover(isPresented: $showingCreateDisk, arrowEdge: .bottom) {
                        createDiskPopover
                    }

                    if storageDiskBinding.wrappedValue.count > 1 {
                        Button("Edit Boot Order...") {
                            showingReorderDisksSheet = true
                        }
                    }
                }
            }
            .disabled(isReadOnly)
            .sheet(isPresented: $showingReorderDisksSheet) {
                StorageDiskReorderSheet(disks: storageDiskBinding, instance: instance)
            }
        }
    }

    @ViewBuilder
    private func storageDiskRow(disk: Binding<StorageDisk>) -> some View {
        HStack {
            Image(systemName: diskIconSystemName(for: disk.wrappedValue))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(disk.wrappedValue.label)
                Text(diskSubtitle(for: disk.wrappedValue, in: instance))
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
    private var createRemovableMediaPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create New Removable Disk")
                .font(.headline)

            Picker("Size", selection: $newDiskSizeInGB) {
                ForEach(VMGuestOS.allDiskSizes, id: \.self) { size in
                    Text(DataFormatters.formatDiskSize(size)).tag(size)
                }
            }

            Text(
                "Creates a writable ASIF sparse disk image at a location you choose, attached as a hot-pluggable USB drive. The file lives outside the VM bundle."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") {
                    showingCreateRemovableMedia = false
                }
                Spacer()
                Button("Create") {
                    showingCreateRemovableMedia = false
                    presentSaveRemovableMedia(for: instance, sizeInGB: newDiskSizeInGB)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 280)
    }

    @ViewBuilder
    private var resourcesSection: some View {
        Section(
            header: sectionHeader("Resources", lockable: true) {
                Text(
                    "Memory is committed to the VM up-front at start time — keep enough free on the host to avoid swap pressure. CPU cores are scheduled by the host; over-committing is fine but reduces per-core performance under load."
                )
            }
        ) {
            let os = instance.configuration.guestOS

            Group {
                Stepper(
                    "CPU Cores: \(instance.configuration.cpuCount)",
                    value: configBinding(\.cpuCount),
                    in: os.minCPUCount...os.maxCPUCount
                )

                Stepper(
                    "Memory: \(instance.configuration.memorySizeInGB) GB",
                    value: configBinding(\.memorySizeInGB),
                    in: os.minMemoryInGB...os.maxMemoryInGB
                )
            }
            .disabled(isReadOnly)
        }
        .task(id: instance.id) {
            await instance.refreshDiskUsage()
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        Section(
            header: sectionHeader("Network", lockable: true) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        "NAT-mode networking. The host assigns the guest a DHCP address on a private subnet. Outbound connections work; there is no port forwarding from host to guest — incoming connections require knowing the guest's IP."
                    )
                    if instance.configuration.guestOS == .linux {
                        Text(
                            "The interface usually appears as `enp0s1`. If networking doesn't come up, make sure your distro's DHCP client or NetworkManager is running."
                        )
                    }
                }
            }
        ) {
            Group {
                Toggle("Networking Enabled", isOn: configBinding(\.networkEnabled))
                if let mac = instance.configuration.macAddress {
                    LabeledContent("MAC Address", value: mac)
                }
            }
            .disabled(isReadOnly)
        }
    }

    @ViewBuilder
    private var audioSection: some View {
        Section(
            header: sectionHeader("Audio", lockable: true) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        "Exposes a VirtioSound device. Speaker output is always enabled; toggle the microphone to grant the guest access to your host mic."
                    )
                    if instance.configuration.guestOS == .linux {
                        Text("Requires Linux kernel 5.14 or newer to detect the VirtioSound device.")
                    }
                }
            }
        ) {
            Group {
                Toggle("Microphone", isOn: configBinding(\.microphoneEnabled))
            }
            .disabled(isReadOnly)

            // Permission warning + info-popover button are left outside the
            // disabled Group so the explanation of how to re-enable the mic
            // in System Settings remains reachable in read-only mode.
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
        Section(header: sectionHeader("Guest Agent")) {
            Toggle(isOn: configBinding(\.agentLogForwardingEnabled)) {
                toggleLabel("Forward guest logs") {
                    Text(
                        "Streams `os.Logger` records from the macOS guest agent to the host so they appear in Console.app under `com.kernova.guest`. Off by default; can be toggled while the VM is running."
                    )
                }
            }

            Toggle(
                isOn: Binding(
                    get: { !instance.configuration.agentInstallNudgeDismissed },
                    set: { newValue in
                        viewModel.updateConfiguration(of: instance) {
                            $0.agentInstallNudgeDismissed = !newValue
                        }
                    }
                )
            ) {
                toggleLabel("Show install reminder") {
                    Text(
                        "Surfaces the install icon in the sidebar when the guest agent has not yet connected. Turn off to suppress the nudge for this VM. The more urgent indicators (update available, didn't reconnect, unresponsive) are not affected."
                    )
                }
            }
        }
    }

    /// Toggle label that pairs a title with a trailing info button.
    ///
    /// Used when the explanation is specific to that one control rather
    /// than to the whole section.
    @ViewBuilder
    private func toggleLabel<Info: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder info: @escaping () -> Info
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
            InfoButton(label: title, content: info)
        }
    }

    @ViewBuilder
    private var clipboardSection: some View {
        Section(
            header: sectionHeader("Clipboard") {
                if instance.configuration.guestOS == .linux {
                    Text(
                        "Exchanges clipboard text between host and guest. Requires `spice-vdagent` installed in the guest via its package manager."
                    )
                } else {
                    Text(
                        "Exchanges clipboard text between host and guest. Uses the bundled Kernova guest agent — Kernova will offer to install or update it from the clipboard window."
                    )
                }
            }
        ) {
            Toggle("Clipboard Sharing", isOn: configBinding(\.clipboardSharingEnabled))
            if isReadOnly && instance.configuration.guestOS == .linux {
                Text("Takes effect on next start — Linux guests configure SPICE at VM start time.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var sharedDirectoriesSection: some View {
        Section(
            header: sectionHeader("Shared Directories", lockable: true) {
                sharedDirectoriesInfo
            }
        ) {
            let directories = sharedDirectoriesBinding.wrappedValue

            Group {
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
            }
            .disabled(isReadOnly)
        }
    }

    @ViewBuilder
    private var sharedDirectoriesInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            if instance.configuration.guestOS == .linux {
                Text(
                    "Exposed as virtiofs mounts. Each share gets a numbered tag (`share0`, `share1`, …) in list order. Mount with:"
                )
                Text("mount -t virtiofs share0 /mnt/myshare")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                Text("Auto-mounts at `/Volumes/My Shared Files/` in the guest.")
            }
            Text(
                "VirtioFS has known framework limitations — files may intermittently appear missing, and host/guest permission mapping can differ."
            )
            .foregroundStyle(.secondary)
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

/// Trailing accessory that reveals per-section or per-control help text in
/// a popover.
///
/// Used both next to section titles (when the explanation applies to the
/// whole section) and next to individual controls (when the explanation is
/// specific to that control). Owns its own `@State` so each call site gets
/// an independent popover anchor.
struct InfoButton<Content: View>: View {
    /// Title of the section or control this button explains.
    ///
    /// Used for the hover tooltip and the VoiceOver label ("About Storage
    /// Disks", "About Forward guest logs", etc.).
    let label: LocalizedStringKey
    let content: () -> Content
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .imageScale(.small)
        }
        .buttonStyle(.plain)
        .help("About \(Text(label))")
        .accessibilityLabel("About \(Text(label))")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            content()
                .font(.callout)
                .padding()
                .frame(width: 340)
        }
    }
}
