import SwiftUI

/// A single row in the sidebar representing a virtual machine.
struct VMRowView: View {
    let instance: VMInstance
    var isRenaming: Bool = false
    var onCommitRename: (String) -> Void = { _ in }
    var onCancelRename: () -> Void = {}
    var onMountAgentInstaller: () -> Void = {}

    @State private var editingName: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: instance.configuration.guestOS.iconName)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Name", text: $editingName)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                        .focused($isTextFieldFocused)
                        .onSubmit {
                            onCommitRename(editingName)
                        }
                        .onExitCommand {
                            onCancelRename()
                        }
                } else {
                    Text(instance.name)
                        .font(.body)
                        .lineLimit(1)
                }

                Text(instance.configuration.guestOS.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let agentStatus = visibleAgentStatus {
                SidebarAgentStatusButton(
                    vmName: instance.name,
                    status: agentStatus,
                    onMount: onMountAgentInstaller
                )
            }

            if instance.isPreparing || instance.status.isTransitioning {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(instance.statusDisplayColor)
                    .frame(width: 8, height: 8)
                    .drawingGroup()
                    .help(instance.statusToolTip ?? "")
            }
        }
        .padding(.vertical, 2)
        .onChange(of: isRenaming) { _, renaming in
            if renaming {
                editingName = instance.name
                isTextFieldFocused = true
            }
        }
        .onChange(of: isTextFieldFocused) { _, focused in
            if !focused && isRenaming {
                onCommitRename(editingName)
            }
        }
    }

    /// The agent status to surface as a sidebar indicator, or `nil` to hide.
    /// Hidden when the guest can't use the Kernova-bundled agent (Linux guests
    /// install spice-vdagent themselves), when no clipboard service is active
    /// (clipboard sharing off, or VM not running), or when the agent is current
    /// (no news is good news).
    private var visibleAgentStatus: AgentStatus? {
        guard instance.configuration.guestOS == .macOS else { return nil }
        guard let service = instance.clipboardService else { return nil }
        let status = service.agentStatus
        if case .current = status { return nil }
        return status
    }
}
