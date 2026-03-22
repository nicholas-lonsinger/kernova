import SwiftUI

/// Step 3: Configure VM name and resource allocation (CPU, RAM, disk).
struct ResourceConfigStep: View {
    @Bindable var creationVM: VMCreationViewModel

    private var os: VMGuestOS { creationVM.selectedOS }

    var body: some View {
        VStack(spacing: 24) {
            Text("Configure Resources")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Set the name and resource allocation for your virtual machine.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Form {
                Section {
                    TextField("Name", text: $creationVM.vmName)
                }

                Section("Compute") {
                    Stepper(
                        "CPU Cores: \(creationVM.cpuCount)",
                        value: $creationVM.cpuCount,
                        in: os.minCPUCount...os.maxCPUCount
                    )

                    Stepper(
                        "Memory: \(creationVM.memoryInGB) GB",
                        value: $creationVM.memoryInGB,
                        in: os.minMemoryInGB...os.maxMemoryInGB
                    )
                }

                Section("Storage") {
                    Picker("Disk Size", selection: $creationVM.diskSizeInGB) {
                        ForEach(os.availableDiskSizes, id: \.self) { size in
                            Text(size >= 1000 ? "\(size / 1000) TB" : "\(size) GB").tag(size)
                        }
                    }

                    Text("Physical disk usage grows only as data is written (ASIF sparse format).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Network") {
                    Toggle("Networking", isOn: $creationVM.networkEnabled)
                }
            }
            .formStyle(.grouped)
        }
    }
}
