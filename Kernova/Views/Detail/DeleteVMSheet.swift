import SwiftUI

/// Confirmation sheet shown when deleting a VM that references external
/// files (storage disks or removable media outside the bundle).
///
/// The simple `.alert(...)` in `LifecycleAlerts` still handles VMs with no
/// external attachments — there's nothing extra to surface in that case.
/// When externals exist, this sheet lists them, flags any that are also
/// referenced by another VM in the library, and offers a single
/// "Also move these files to Trash" toggle. Trashing applies to every
/// listed file (including shared ones); the warning is the user's cue to
/// uncheck the toggle if they'd rather keep the shared files.
@MainActor
struct DeleteVMSheet: View {
    let instance: VMInstance
    let externals: [ExternalAttachment]
    @Binding var trashExternals: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var anyShared: Bool { externals.contains(where: \.isShared) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(externals) { external in
                        row(for: external)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            Divider()
            footer
        }
        .frame(width: 520)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "trash")
                .font(.title)
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Move \u{201C}\(instance.name)\u{201D} to Trash?")
                    .font(.headline)
                Text(
                    "The VM bundle will be moved to the Trash. You can restore it using Finder's Put Back command. Empty the Trash to permanently delete the VM and reclaim disk space."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    @ViewBuilder
    private func row(for external: ExternalAttachment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: external.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(external.label)
                    .font(.body)
                Text(external.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if external.isShared {
                    Label {
                        Text("Also used by \(formatSharedVMs(external.sharedWithVMNames))")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Also move these files to Trash", isOn: $trashExternals)
                .toggleStyle(.checkbox)
            if trashExternals && anyShared {
                Label {
                    Text(
                        "Files marked as shared will become unavailable to the VMs listed above."
                    )
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func formatSharedVMs(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return "\u{201C}\(names[0])\u{201D}"
        case 2: return "\u{201C}\(names[0])\u{201D} and \u{201C}\(names[1])\u{201D}"
        default:
            let head = names.dropLast().map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
            return "\(head), and \u{201C}\(names.last ?? "")\u{201D}"
        }
    }
}

extension ExternalAttachment {
    /// SF Symbol for the row icon, matching the iconography elsewhere in
    /// the storage settings UI (`externaldrive` for disks, `opticaldisc`
    /// for removable media on the XHCI controller).
    fileprivate var symbolName: String {
        switch kind {
        case .storageDisk: return "externaldrive"
        case .removableMedia: return "opticaldisc"
        }
    }
}
