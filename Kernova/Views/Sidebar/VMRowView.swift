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
    ///
    /// Hidden when:
    /// - The guest can't use the Kernova-bundled agent (Linux installs
    ///   spice-vdagent itself).
    /// - macOS install is in progress (no agent yet, by design).
    /// - The agent is `.current` (no news is good news).
    /// - The VM is currently stopped or cold-paused **and** we have already
    ///   seen the agent on this VM (`lastSeenAgentVersion != nil`). In that
    ///   case the `.waiting` badge would just nag — the version is safely
    ///   persisted and the live state will resurface on next start.
    ///
    /// `.waiting`, `.outdated`, `.unresponsive`, and `.expectedMissing` are
    /// surfaced when applicable so the user has something to act on.
    private var visibleAgentStatus: AgentStatus? {
        guard instance.configuration.guestOS == .macOS else { return nil }
        guard instance.installState == nil else { return nil }
        let status = instance.agentStatus
        if case .current = status { return nil }
        // For stopped / cold-paused VMs we'd otherwise show `.waiting`. If
        // the agent has previously connected, suppress that nudge — we only
        // want to surface live-session signals (`.outdated` / `.unresponsive`
        // / `.expectedMissing`) on running VMs. The watchdog only fires while
        // running, so `.expectedMissing` only reaches here for live sessions.
        let isLiveSession = instance.virtualMachine != nil
        if !isLiveSession,
           case .waiting = status,
           instance.configuration.lastSeenAgentVersion != nil {
            return nil
        }
        return status
    }
}
