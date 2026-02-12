import SwiftUI

/// Settings form for editing a stopped VM's configuration.
struct VMSettingsView: View {
    @Bindable var instance: VMInstance
    @Bindable var viewModel: VMLibraryViewModel

    var body: some View {
        ScrollView {
            Form {
                generalSection
                resourcesSection
                networkSection
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
    private var notesSection: some View {
        Section("Notes") {
            TextEditor(text: $instance.configuration.notes)
                .frame(minHeight: 60)
        }
    }
}
