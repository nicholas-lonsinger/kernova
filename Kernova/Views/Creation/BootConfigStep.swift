import SwiftUI
import UniformTypeIdentifiers

/// Step 2 (Linux): Configure boot method — EFI with ISO or direct kernel boot.
struct BootConfigStep: View {
    @Bindable var creationVM: VMCreationViewModel

    var body: some View {
        VStack(spacing: 24) {
            Text("Boot Configuration")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Choose how to boot your Linux virtual machine.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Picker("Boot Mode", selection: $creationVM.selectedBootMode) {
                Text("EFI (ISO Image)").tag(VMBootMode.efi)
                Text("Linux Kernel").tag(VMBootMode.linuxKernel)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)

            Group {
                if creationVM.selectedBootMode == .efi {
                    efiConfig
                } else {
                    kernelConfig
                }
            }
        }
    }

    private var efiConfig: some View {
        VStack(spacing: 12) {
            Text("Select an ISO image to boot from via EFI.")
                .font(.caption)
                .foregroundStyle(.secondary)

            filePickerRow(
                label: "ISO Image",
                path: creationVM.isoPath,
                allowedTypes: [.iso]
            ) { url in
                creationVM.isoPath = url.path
            }
        }
    }

    private var kernelConfig: some View {
        VStack(spacing: 12) {
            Text("Provide the kernel image and optional initrd/command line.")
                .font(.caption)
                .foregroundStyle(.secondary)

            filePickerRow(
                label: "Kernel",
                path: creationVM.kernelPath,
                allowedTypes: [.data]
            ) { url in
                creationVM.kernelPath = url.path
            }

            filePickerRow(
                label: "Initrd",
                path: creationVM.initrdPath,
                allowedTypes: [.data]
            ) { url in
                creationVM.initrdPath = url.path
            }

            TextField(
                "Kernel Command Line",
                text: Binding(
                    get: { creationVM.kernelCommandLine ?? "console=hvc0" },
                    set: { creationVM.kernelCommandLine = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
        }
    }

    private func filePickerRow(
        label: String,
        path: String?,
        allowedTypes: [UTType],
        onSelect: @escaping (URL) -> Void
    ) -> some View {
        HStack {
            Text(label)
                .frame(width: 60, alignment: .trailing)

            if let path {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No file selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("Browse...") {
                let panel = NSOpenPanel()
                panel.title = "Select \(label)"
                panel.allowedContentTypes = allowedTypes
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false

                if panel.runModal() == .OK, let url = panel.url {
                    onSelect(url)
                }
            }
        }
    }
}
