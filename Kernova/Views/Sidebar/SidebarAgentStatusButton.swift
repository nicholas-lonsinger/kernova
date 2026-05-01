import SwiftUI

/// Trailing accessory shown in the sidebar row when the guest agent needs the
/// user's attention — either it's not installed, or the installed version is
/// older than what this build of Kernova bundles.
///
/// Click opens a popover anchored to the button with the install/update
/// affordance, so users can act on the situation without opening the clipboard
/// window. This is the single notification surface for agent-driven features
/// (clipboard sync today, drag/drop file copy and auto passthrough later).
struct SidebarAgentStatusButton: View {
    let vmName: String
    let status: AgentStatus
    let onMount: () -> Void

    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented = true
        } label: {
            Image(systemName: symbolName)
                .foregroundStyle(symbolColor)
                .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.plain)
        .help(helpText)
        // arrowEdge: .leading places the arrow on the popover's leading edge,
        // which sits the popover to the trailing side of the button — i.e. over
        // the detail pane, where there's room.
        .popover(isPresented: $isPopoverPresented, arrowEdge: .leading) {
            AgentStatusPopoverContent(
                vmName: vmName,
                status: status,
                onAction: {
                    if case .current = status {
                        // Done — just close
                    } else {
                        onMount()
                    }
                    isPopoverPresented = false
                }
            )
        }
    }

    // MARK: - Visual mapping

    private var symbolName: String {
        switch status {
        case .waiting: "exclamationmark.circle.fill"
        case .outdated: "arrow.triangle.2.circlepath.circle.fill"
        case .current: "checkmark.circle.fill"
        }
    }

    private var symbolColor: Color {
        switch status {
        case .waiting: .secondary
        case .outdated: .orange
        case .current: .green
        }
    }

    private var helpText: String {
        switch status {
        case .waiting: "Guest agent not installed"
        case .outdated(let installed, let bundled): "Guest agent update available (\(installed) → \(bundled))"
        case .current(let version): "Guest agent connected (\(version))"
        }
    }
}

/// Body of the agent-status popover, extracted from `SidebarAgentStatusButton`
/// so it can be previewed and tuned without clicking the popover open.
///
/// The trailing `.fixedSize()` (both dimensions) is what makes NSPopover size
/// correctly. With horizontal flexible the inner Text renders on one line and
/// gets clipped to the inner frame; pinning both dimensions to intrinsic
/// produces a wrapped, naturally-tall layout NSPopover can host without
/// negotiation.
struct AgentStatusPopoverContent: View {
    let vmName: String
    let status: AgentStatus
    let onAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(popoverTitle).font(.headline)
            Text(popoverBody)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(buttonTitle, action: onAction)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 320, alignment: .leading)
        .padding(16)
        .fixedSize()
    }

    private var popoverTitle: String {
        switch status {
        case .waiting: "Set up the Kernova guest agent"
        case .outdated: "Update available"
        case .current: "Guest agent connected"
        }
    }

    private var popoverBody: String {
        switch status {
        case .waiting:
            return "The Kernova guest agent enables clipboard sync with \(vmName). Mounting the installer presents it as a disk inside the VM — open it in Finder and run install.command."
        case .outdated(let installed, let bundled):
            return "\(vmName) is running guest agent \(installed). Kernova bundles \(bundled). Mounting the installer presents it as a disk inside the VM — open it in Finder and run install.command."
        case .current(let version):
            return "\(vmName) is connected with guest agent \(version)."
        }
    }

    private var buttonTitle: String {
        switch status {
        case .waiting: "Install Guest Agent…"
        case .outdated: "Update Guest Agent…"
        case .current: "Done"
        }
    }
}

// MARK: - Previews

// Sidebar button + click target. Click the icon to open the live popover.
#Preview("Button — Waiting") {
    SidebarAgentStatusButton(
        vmName: "Sequoia Dev",
        status: .waiting,
        onMount: {}
    )
    .padding(40)
}

#Preview("Button — Outdated") {
    SidebarAgentStatusButton(
        vmName: "Sequoia Dev",
        status: .outdated(installed: "0.9.1", bundled: "0.9.2"),
        onMount: {}
    )
    .padding(40)
}

#Preview("Button — Current") {
    SidebarAgentStatusButton(
        vmName: "Sequoia Dev",
        status: .current(version: "0.9.2"),
        onMount: {}
    )
    .padding(40)
}

// Standalone popover content — always visible in the canvas, lets you iterate
// on text wrapping and sizing without clicking the button each time.
#Preview("Popover — Waiting") {
    AgentStatusPopoverContent(
        vmName: "Sequoia Dev",
        status: .waiting,
        onAction: {}
    )
}

#Preview("Popover — Outdated") {
    AgentStatusPopoverContent(
        vmName: "Sequoia Dev",
        status: .outdated(installed: "0.9.1", bundled: "0.9.2"),
        onAction: {}
    )
}

#Preview("Popover — Current") {
    AgentStatusPopoverContent(
        vmName: "Sequoia Dev",
        status: .current(version: "0.9.2"),
        onAction: {}
    )
}

#Preview("Popover — Long VM name") {
    AgentStatusPopoverContent(
        vmName: "My Very Long macOS Sequoia Development VM Name",
        status: .outdated(installed: "0.9.1", bundled: "0.9.2"),
        onAction: {}
    )
}
