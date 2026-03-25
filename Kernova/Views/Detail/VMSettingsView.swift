import AVFoundation
import SwiftUI

/// Settings form for editing a stopped VM's configuration.
struct VMSettingsView: View {
    @Bindable var instance: VMInstance
    @Bindable var viewModel: VMLibraryViewModel

    @State private var editingName = ""
    @State private var showingDiskInfo = false
    @State private var showingMicPermissionInfo = false
    @State private var micPermission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var showingCreateDisk = false
    @State private var newDiskSizeInGB = 50
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

    /// Binding that unwraps the optional storage disks array, defaulting to empty.
    private var storageDiskBinding: Binding<[AdditionalDisk]> {
        Binding(
            get: { instance.configuration.additionalDisks ?? [] },
            set: { instance.configuration.additionalDisks = $0.isEmpty ? nil : $0 }
        )
    }

    /// Binding that unwraps the optional shared directories array, defaulting to empty.
    private var sharedDirectoriesBinding: Binding<[SharedDirectory]> {
        Binding(
            get: { instance.configuration.sharedDirectories ?? [] },
            set: { instance.configuration.sharedDirectories = $0.isEmpty ? nil : $0 }
        )
    }

    var body: some View {
        ScrollView {
            Form {
                generalSection
                resourcesSection
                storageDiskSection
                removableMediaSection
                sharedDirectoriesSection
                networkSection
                audioSection
                clipboardSection
            }
            .formStyle(.grouped)
            .padding()
        }
        .onChange(of: instance.configuration) { _, _ in
            viewModel.saveConfiguration(for: instance)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var generalSection: some View {
        Section("General") {
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
                Button { viewModel.renameVM(instance) } label: {
                    LabeledContent("Name") {
                        Text(instance.name)
                    }
                }
                .buttonStyle(.plain)
            }
            LabeledContent("Type", value: instance.configuration.guestOS.displayName)
            LabeledContent("Boot Mode", value: instance.configuration.bootMode.displayName)
            LabeledContent("Created", value: instance.configuration.createdAt.formatted(date: .abbreviated, time: .shortened))
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
            if let discImagePath = instance.configuration.discImagePath {
                HStack {
                    Image(systemName: "opticaldisc")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: discImagePath).lastPathComponent)
                        Text(discImagePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button(role: .destructive) {
                        instance.configuration.discImagePath = nil
                        instance.configuration.bootFromDiscImage = false
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }

                Toggle("Read Only", isOn: $instance.configuration.discImageReadOnly)

                if instance.configuration.bootMode == .efi {
                    Toggle("Boot from disc image", isOn: $instance.configuration.bootFromDiscImage)
                }
            } else {
                Text("No removable media attached")
                    .foregroundStyle(.secondary)
            }

            Button(instance.configuration.discImagePath != nil ? "Change Disc Image..." : "Attach Disc Image...") {
                browseRemovableMedia()
            }

            Text("Appears as a USB drive in the guest. Use for installer ISOs, recovery images, or file transfer. When read-only is off, changes are written back to the disk image file.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func browseRemovableMedia() {
        guard let url = NSOpenPanel.browseDiskImages(
            message: "Select a disk image to attach to the VM"
        ).first else { return }
        instance.configuration.discImagePath = url.path(percentEncoded: false)
    }

    // MARK: - Storage Disks

    @ViewBuilder
    private var storageDiskSection: some View {
        Section {
            let disks = storageDiskBinding.wrappedValue

            if disks.isEmpty {
                Text("No storage disks attached")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(storageDiskBinding) { $disk in
                    HStack {
                        Image(systemName: disk.isInternal ? "internaldrive" : "externaldrive")
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(disk.label)
                            Text(disk.isInternal ? "In-bundle ASIF disk" : disk.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Toggle("Read Only", isOn: $disk.readOnly)
                            .toggleStyle(.switch)
                            .labelsHidden()
                        Text("Read Only")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(role: .destructive) {
                            viewModel.removeAdditionalDisk(disk, from: instance)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
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

            Text("Storage disks provide high-performance persistent storage. They appear as block devices in the guest (e.g., /dev/vdb on Linux) and support TRIM for efficient space usage.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if instance.configuration.guestOS == .linux && !disks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Find in guest:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(disks) { disk in
                        Text("/dev/disk/by-id/virtio-\(disk.blockDeviceIdentifier)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text("Storage Disks")
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
            current.append(AdditionalDisk(path: path))
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
                    viewModel.createAdditionalDisk(for: instance, sizeInGB: newDiskSizeInGB)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 280)
    }

    @ViewBuilder
    private var resourcesSection: some View {
        Section("Resources") {
            let os = instance.configuration.guestOS

            Stepper(
                "CPU Cores: \(instance.configuration.cpuCount)",
                value: $instance.configuration.cpuCount,
                in: os.minCPUCount...os.maxCPUCount
            )

            Stepper(
                "Memory: \(instance.configuration.memorySizeInGB) GB",
                value: $instance.configuration.memorySizeInGB,
                in: os.minMemoryInGB...os.maxMemoryInGB
            )

            LabeledContent {
                HStack {
                    if let usage = instance.cachedDiskUsageBytes {
                        Text("\(DataFormatters.formatBytes(usage)) (on disk) / \(DataFormatters.formatDiskSize(instance.configuration.diskSizeInGB)) (allocated)")
                    } else {
                        Text(DataFormatters.formatDiskSize(instance.configuration.diskSizeInGB))
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Disk Size")
                    Button {
                        showingDiskInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingDiskInfo, arrowEdge: .trailing) {
                        diskInfoPopover
                    }
                }
            }
        }
        .task(id: instance.id) {
            await instance.refreshDiskUsage()
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        Section("Network") {
            Toggle("Networking Enabled", isOn: $instance.configuration.networkEnabled)
            if let mac = instance.configuration.macAddress {
                LabeledContent("MAC Address", value: mac)
            }
        }
    }

    @ViewBuilder
    private var audioSection: some View {
        Section("Audio") {
            Toggle("Microphone", isOn: $instance.configuration.microphoneEnabled)
            Text("Allows the guest to access the host microphone. Speaker output is always enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if instance.configuration.microphoneEnabled {
                if micPermission == .notDetermined {
                    Text("macOS will ask for microphone permission the first time a VM uses it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if micPermission == .denied || micPermission == .restricted {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)

                        Text("Microphone permission is denied. Enable it in System Settings for Kernova to pass your microphone to VMs.")
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
    private var clipboardSection: some View {
        Section("Clipboard") {
            Toggle("Clipboard Sharing", isOn: $instance.configuration.clipboardSharingEnabled)
            Text("Enables a SPICE clipboard channel for exchanging text between host and guest. The guest must have a SPICE agent installed (e.g. spice-vdagent on Linux).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sharedDirectoriesSection: some View {
        Section {
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
                Text("Shared directories are available as virtiofs mounts in the guest. Mount them with `mount -t virtiofs <tag> <mountpoint>`.")
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
                Text("Note: File sharing uses VirtioFS which has known framework limitations — files may intermittently appear missing, and permission mapping between host and guest can differ.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Shared Directories")
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
    private var diskInfoPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Disk Size")
                .font(.headline)

            Text("This VM uses a fixed-size ASIF (Apple Sparse Image Format) disk. The image only consumes physical disk space as data is written.")

            Divider()

            Text("Expanding the disk")
                .font(.subheadline)
                .fontWeight(.medium)

            Text("To resize the disk image, use Terminal:")
                .font(.callout)

            Text("diskutil image resize --size <new-size>g \\\n  <path-to-Disk.asif>")
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Text("Alternatively, add a storage disk or shared directory to transfer data without resizing.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 340)
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
