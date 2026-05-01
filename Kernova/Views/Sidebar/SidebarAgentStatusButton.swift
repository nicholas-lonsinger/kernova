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
        .popover(isPresented: $isPopoverPresented, arrowEdge: .trailing) {
            popoverContent
                .padding(16)
                .frame(width: 280)
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

    // MARK: - Popover

    @ViewBuilder
    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(popoverTitle).font(.headline)
            Text(popoverBody)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                if case .current = status {
                    Button("Done") { isPopoverPresented = false }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(buttonTitle) {
                        onMount()
                        isPopoverPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
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
