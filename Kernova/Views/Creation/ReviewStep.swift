import SwiftUI

/// Step 4: Review the VM configuration before creation.
struct ReviewStep: View {
    let creationVM: VMCreationViewModel

    var body: some View {
        VStack(spacing: 24) {
            Text("Review Configuration")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Review your virtual machine settings before creating it.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Form {
                Section("General") {
                    LabeledContent("Name", value: creationVM.vmName)
                    LabeledContent("Operating System", value: creationVM.selectedOS.displayName)
                    LabeledContent("Boot Mode", value: creationVM.effectiveBootMode.displayName)
                }

                Section("Resources") {
                    LabeledContent("CPU Cores", value: "\(creationVM.cpuCount)")
                    LabeledContent("Memory", value: "\(creationVM.memoryInGB) GB")
                    LabeledContent("Disk Size", value: "\(creationVM.diskSizeInGB) GB")
                }

                Section("Network") {
                    LabeledContent("Networking", value: creationVM.networkEnabled ? "Enabled" : "Disabled")
                }

                if creationVM.selectedOS == .macOS {
                    Section("Installation") {
                        LabeledContent("IPSW Source") {
                            Text(creationVM.ipswSource == .downloadLatest ? "Download Latest" : "Local File")
                        }
                        if let path = creationVM.ipswPath {
                            LabeledContent("File", value: URL(fileURLWithPath: path).lastPathComponent)
                        }
                    }
                }

                if creationVM.selectedOS == .linux {
                    Section("Boot") {
                        if let path = creationVM.isoPath {
                            LabeledContent("ISO", value: URL(fileURLWithPath: path).lastPathComponent)
                        }
                        if let path = creationVM.kernelPath {
                            LabeledContent("Kernel", value: URL(fileURLWithPath: path).lastPathComponent)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}
