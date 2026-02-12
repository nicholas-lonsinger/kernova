import SwiftUI

/// Read-only info panel for a running VM, shown alongside the console.
struct VMInfoView: View {
    let instance: VMInstance

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("State") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(instance.status.statusColor)
                            .frame(width: 8, height: 8)
                        Text(instance.status.displayName)
                    }
                }
            }

            Section("Configuration") {
                LabeledContent("OS", value: instance.configuration.guestOS.displayName)
                LabeledContent("CPU Cores", value: "\(instance.configuration.cpuCount)")
                LabeledContent("Memory", value: DataFormatters.formatBytes(
                    UInt64(instance.configuration.memorySizeInGB) * 1024 * 1024 * 1024
                ))
                LabeledContent("Disk", value: "\(instance.configuration.diskSizeInGB) GB")
            }

            Section("Network") {
                LabeledContent("Enabled", value: instance.configuration.networkEnabled ? "Yes" : "No")
                if let mac = instance.configuration.macAddress {
                    LabeledContent("MAC Address", value: mac)
                }
            }

            if let directories = instance.configuration.sharedDirectories, !directories.isEmpty {
                Section("Shared Directories") {
                    ForEach(directories) { directory in
                        LabeledContent(directory.displayName) {
                            Text(directory.readOnly ? "Read Only" : "Read/Write")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
