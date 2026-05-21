import SwiftUI

/// Modal sheet for reordering a VM's storage disks.
///
/// Uses a real `List` with `.onMove` — the same pattern as `SidebarView` —
/// so SwiftUI provides native drop affordances (insertion indicator between
/// rows, drop-to-end). Writes flow through the supplied `disks` binding,
/// which the parent wires to `VMSettingsView.storageDiskBinding`; every
/// reorder therefore goes through `viewModel.updateConfiguration` and is
/// persisted immediately.
@MainActor
struct StorageDiskReorderSheet: View {
    @Binding var disks: [StorageDisk]
    let instance: VMInstance
    let fileMonitor: AttachmentFileMonitor

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Boot Order")
                    .font(.headline)
                InfoButton(label: "Boot Order") {
                    Text(
                        "Drag rows to set the order in which the guest sees its storage. Position 1 boots first on EFI guests; on macOS and Linux Kernel boot, the order also determines guest device enumeration (for example, /dev/vda, /dev/vdb)."
                    )
                }
                Spacer()
            }
            .padding()

            Divider()

            List {
                ForEach($disks) { $disk in
                    row(for: disk)
                }
                .onMove { source, destination in
                    disks.move(fromOffsets: source, toOffset: destination)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    @ViewBuilder
    private func row(for disk: StorageDisk) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            let isMissing = !disk.isInternal && !fileMonitor.exists(disk.path)
            AttachmentIcon(
                systemName: diskIconSystemName(for: disk),
                missingTooltip: isMissing ? missingAttachmentTooltip : nil
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(disk.label)
                attachmentSubtitle(
                    path: diskSubtitle(for: disk, in: instance),
                    isMissing: isMissing
                )
            }

            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}
