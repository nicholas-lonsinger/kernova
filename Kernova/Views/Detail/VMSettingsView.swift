import SwiftUI
import UniformTypeIdentifiers

/// Settings form for editing a stopped VM's configuration.
struct VMSettingsView: View {
    @Bindable var instance: VMInstance
    @Bindable var viewModel: VMLibraryViewModel

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
                sharedDirectoriesSection
                notesSection
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
            TextField("Name", text: $instance.configuration.name)
            LabeledContent("Type", value: instance.configuration.guestOS.displayName)
            LabeledContent("Boot Mode", value: instance.configuration.bootMode.displayName)
            LabeledContent("Created", value: instance.configuration.createdAt.formatted(date: .abbreviated, time: .shortened))
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
                        Text((isoPath as NSString).lastPathComponent)
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
        instance.configuration.isoPath = url.path
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

            LabeledContent("Disk Size", value: "\(instance.configuration.diskSizeInGB) GB")
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
    private var sharedDirectoriesSection: some View {
        Section {
            let directories = sharedDirectoriesBinding.wrappedValue

            if directories.isEmpty {
                Text("No shared directories")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(directories) { directory in
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

                        if let index = directories.firstIndex(where: { $0.id == directory.id }) {
                            Toggle("Read Only", isOn: sharedDirectoriesBinding[index].readOnly)
                                .toggleStyle(.switch)
                                .labelsHidden()
                            Text("Read Only")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

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
            let path = url.path
            guard !existingPaths.contains(path) else { continue }
            current.append(SharedDirectory(path: path))
        }

        sharedDirectoriesBinding.wrappedValue = current
    }

    @ViewBuilder
    private var notesSection: some View {
        Section("Notes") {
            TextEditor(text: $instance.configuration.notes)
                .frame(minHeight: 60)
        }
    }
}
