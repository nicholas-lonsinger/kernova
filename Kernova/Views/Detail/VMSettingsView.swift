import SwiftUI
import UniformTypeIdentifiers

/// Settings form for editing a stopped VM's configuration.
struct VMSettingsView: View {
    @Bindable var instance: VMInstance
    @Bindable var viewModel: VMLibraryViewModel

    @State private var editingName = ""
    @State private var showingDiskInfo = false
    @FocusState private var isNameFieldFocused: Bool

    private var isRenaming: Bool {
        viewModel.activeRename == .detail(instance.id)
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
                discImageSection
                resourcesSection
                networkSection
                clipboardSection
                sharedDirectoriesSection
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
    private var discImageSection: some View {
        Section("Disc Image") {
            if let isoPath = instance.configuration.isoPath {
                HStack {
                    Image(systemName: "opticaldisc")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: isoPath).lastPathComponent)
                        Text(isoPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button(role: .destructive) {
                        instance.configuration.isoPath = nil
                        instance.configuration.bootFromDiscImage = false
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }

                if instance.configuration.bootMode == .efi {
                    Toggle("Boot from disc image", isOn: $instance.configuration.bootFromDiscImage)
                }
            } else {
                Text("No disc image attached")
                    .foregroundStyle(.secondary)
            }

            Button(instance.configuration.isoPath != nil ? "Change Disc Image..." : "Browse Disc Image...") {
                browseISOImage()
            }

            Text("Appears as a USB drive in the guest.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func browseISOImage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
        panel.message = "Select an ISO image to attach to the VM"
        panel.prompt = "Attach"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        instance.configuration.isoPath = url.path(percentEncoded: false)
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

            Text("Alternatively, attach an additional ISO or shared directory to transfer data without resizing.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 340)
    }
}
