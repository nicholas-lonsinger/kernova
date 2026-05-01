import SwiftUI
import AppKit

/// Trailing accessory shown in the sidebar row when the guest agent needs the
/// user's attention — either it's not installed, or the installed version is
/// older than what this build of Kernova bundles.
///
/// Click opens a popover anchored to the button with the install/update
/// affordance, so users can act on the situation without opening the clipboard
/// window. This is the single notification surface for agent-driven features
/// (clipboard sync today, drag/drop file copy and auto passthrough later).
///
/// ## Why this uses NSPopover instead of SwiftUI's `.popover`
/// SwiftUI's `.popover` modifier wraps the content in an `NSHostingController`
/// whose `sizingOptions` are not configurable. That host doesn't propagate
/// `.fixedSize()` to NSPopover's `contentSize` reliably, so the body Text
/// rendered as a single line and was clipped horizontally with an ellipsis.
/// Bridging directly to `NSPopover` + `NSHostingController` lets us set
/// `sizingOptions = .preferredContentSize` explicitly, which is the pattern
/// `RemovableMediaPopoverView` already uses successfully.
struct SidebarAgentStatusButton: View {
    let vmName: String
    let status: AgentStatus
    let onMount: () -> Void

    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            Image(systemName: symbolName)
                .foregroundStyle(symbolColor)
                .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.plain)
        .help(helpText)
        .background(
            NSPopoverAnchor(
                isPresented: $isPopoverPresented,
                preferredEdge: .maxX
            ) {
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
        )
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
/// Width is pinned at 320 by the inner frame; padding wraps the content; the
/// trailing `.fixedSize()` makes both dimensions intrinsic so when this view is
/// hosted by `NSHostingController` with `sizingOptions = .preferredContentSize`,
/// `NSPopover` gets a fully-determined content size and the body wraps cleanly.
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

/// Bridges a SwiftUI binding to an `NSPopover` whose content view controller
/// is configured with `sizingOptions = .preferredContentSize`.
///
/// Place behind a SwiftUI control via `.background(NSPopoverAnchor(...))`:
/// the representable's hidden `NSView` becomes the popover's anchor, and
/// flipping `isPresented` shows or closes the popover.
private struct NSPopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let preferredEdge: NSRectEdge
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isPresented = $isPresented
        coordinator.anchor = nsView

        if isPresented {
            coordinator.show(
                content: content(),
                from: nsView,
                preferredEdge: preferredEdge
            )
        } else {
            coordinator.close()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        var isPresented: Binding<Bool>
        weak var anchor: NSView?
        private var popover: NSPopover?

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
        }

        func show<C: View>(content: C, from anchor: NSView, preferredEdge: NSRectEdge) {
            // Already showing? Just leave it alone — re-presenting causes flicker.
            if let popover, popover.isShown { return }

            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = self

            let hostingController = NSHostingController(rootView: content)
            // .preferredContentSize is the linchpin: it tells NSHostingController
            // to publish the SwiftUI view's intrinsic size as the popover's
            // contentSize. SwiftUI's built-in .popover modifier does not set
            // this option, which is what was clipping the body to one line.
            hostingController.sizingOptions = .preferredContentSize
            popover.contentViewController = hostingController

            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: preferredEdge)
            self.popover = popover
        }

        func close() {
            popover?.performClose(nil)
            popover = nil
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            // Sync the binding back to false when the user dismisses the
            // popover (click outside, Esc, etc.) so the parent view's state
            // matches reality.
            if isPresented.wrappedValue {
                isPresented.wrappedValue = false
            }
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
