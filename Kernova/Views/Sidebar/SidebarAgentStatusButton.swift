import SwiftUI
import AppKit

/// Trailing accessory shown in the sidebar row when the guest agent needs the
/// user's attention — either it's not installed, or the installed version is
/// older than what this build of Kernova bundles.
///
/// Click opens an `NSPopover` with the install/update affordance, so users can
/// act on the situation without opening the clipboard window. This is the
/// single notification surface for agent-driven features (clipboard sync today,
/// drag/drop file copy and auto passthrough later).
///
/// ## Why this uses NSPopover with an explicit contentSize
/// SwiftUI's `.popover` modifier and `NSHostingController` with various
/// `sizingOptions` both fail to size a multi-line-text popover correctly on
/// macOS Tahoe — the body Text renders single-line and clips with an ellipsis.
/// The fix is to bypass SwiftUI's sizing-up-to-host model entirely: measure
/// the body text with `NSAttributedString.boundingRect`, set
/// `popover.contentSize` to a known-good (width, computed-height), and let the
/// SwiftUI view fill that bounded rectangle. Text wraps naturally to the
/// bounded width with no `.frame(width:)` or `.fixedSize()` involved.
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
                contentSize: AgentStatusPopoverMetrics.contentSize(
                    forStatus: status,
                    vmName: vmName
                ),
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

// MARK: - Popover content & metrics

/// Body of the agent-status popover. Designed to **fill** its host (the
/// popover's content area is sized externally by `AgentStatusPopoverMetrics`)
/// rather than dictate its own size — `.frame(maxWidth: .infinity, …)` lets it
/// expand into the bounded region, and Text wraps naturally to that width with
/// no `.frame(width:)` or `.fixedSize()` modifiers needed.
struct AgentStatusPopoverContent: View {
    let vmName: String
    let status: AgentStatus
    let onAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AgentStatusPopoverMetrics.verticalSpacing) {
            Text(AgentStatusPopoverMetrics.title(for: status))
                .font(.headline)

            Text(AgentStatusPopoverMetrics.bodyText(for: status, vmName: vmName))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)

            HStack {
                Spacer()
                Button(buttonTitle, action: onAction)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AgentStatusPopoverMetrics.padding)
        // Hard-pin width so the SwiftUI ideal width is exactly contentWidth.
        // Without this the ideal width is the body Text's single-line width
        // (huge), and NSHostingController publishes that as preferredContentSize,
        // overriding popover.contentSize. The result was a wide popover with
        // the body Text on one line clipped at the screen edge.
        .frame(width: AgentStatusPopoverMetrics.contentWidth, alignment: .topLeading)
    }

    private var buttonTitle: String {
        switch status {
        case .waiting: "Install Guest Agent…"
        case .outdated: "Update Guest Agent…"
        case .current: "Done"
        }
    }
}

/// Static helpers that compute the popover's `contentSize` and the per-status
/// strings. Centralized here so `AgentStatusPopoverContent` and
/// `SidebarAgentStatusButton` agree on the layout numbers used for the
/// `NSPopover` content size and the SwiftUI padding/spacing.
enum AgentStatusPopoverMetrics {
    static let contentWidth: CGFloat = 360
    static let padding: CGFloat = 16
    static let verticalSpacing: CGFloat = 10

    /// Approximate `.headline` line height, including SwiftUI's default
    /// padding around the baseline. Hard-coded because we don't have layout
    /// access at the point we need to size the popover.
    private static let titleLineHeight: CGFloat = 22

    /// Standard `.regular` SwiftUI button height for `.keyboardShortcut(.defaultAction)`.
    private static let buttonHeight: CGFloat = 28

    static func contentSize(forStatus status: AgentStatus, vmName: String) -> NSSize {
        let textWidth = contentWidth - padding * 2
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let body = bodyText(for: status, vmName: vmName) as NSString
        let bodyRect = body.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )

        let height = padding             // top
            + titleLineHeight             // headline
            + verticalSpacing             // gap before body
            + ceil(bodyRect.height)       // wrapped body
            + verticalSpacing             // gap before button row
            + buttonHeight                // button
            + padding                     // bottom
        return NSSize(width: contentWidth, height: ceil(height))
    }

    static func title(for status: AgentStatus) -> String {
        switch status {
        case .waiting: "Set up the Kernova guest agent"
        case .outdated: "Update available"
        case .current: "Guest agent connected"
        }
    }

    static func bodyText(for status: AgentStatus, vmName: String) -> String {
        switch status {
        case .waiting:
            return "The Kernova guest agent enables clipboard sync with \(vmName). Mounting the installer presents it as a disk inside the VM — open it in Finder and run install.command."
        case .outdated(let installed, let bundled):
            return "\(vmName) is running guest agent \(installed). Kernova bundles \(bundled). Mounting the installer presents it as a disk inside the VM — open it in Finder and run install.command."
        case .current(let version):
            return "\(vmName) is connected with guest agent \(version)."
        }
    }
}

// MARK: - NSPopover bridge

/// Bridges a SwiftUI `Bool` binding to an `NSPopover` whose `contentSize` is
/// supplied by the caller. The host SwiftUI view (typically placed via
/// `.background(NSPopoverAnchor(...))`) provides the anchor `NSView`; flipping
/// the binding shows or closes the popover.
private struct NSPopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let contentSize: NSSize
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
                contentSize: contentSize,
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

        func show<C: View>(
            content: C,
            contentSize: NSSize,
            from anchor: NSView,
            preferredEdge: NSRectEdge
        ) {
            // Already showing? Just leave it alone — re-presenting causes flicker.
            if let popover, popover.isShown { return }

            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = self

            let hostingController = NSHostingController(rootView: content)
            // Both popover.contentSize AND hostingController.preferredContentSize
            // need to be set. Per Apple's NSPopover docs: if the
            // contentViewController has a non-zero preferredContentSize, the
            // popover uses *that* and ignores popover.contentSize. Without
            // pinning preferredContentSize here, NSHostingController publishes
            // the SwiftUI view's ideal size — which can balloon if the inner
            // content has unbounded width — and overrides our explicit sizing.
            hostingController.preferredContentSize = contentSize
            popover.contentSize = contentSize
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

// Standalone popover content rendered in a fixed frame matching the actual
// popover content size, so the canvas mirrors what NSPopover will display.
#Preview("Popover — Waiting") {
    AgentStatusPopoverContent(
        vmName: "Sequoia Dev",
        status: .waiting,
        onAction: {}
    )
    .frame(
        width: AgentStatusPopoverMetrics.contentSize(forStatus: .waiting, vmName: "Sequoia Dev").width,
        height: AgentStatusPopoverMetrics.contentSize(forStatus: .waiting, vmName: "Sequoia Dev").height
    )
}

#Preview("Popover — Outdated") {
    AgentStatusPopoverContent(
        vmName: "Sequoia Dev",
        status: .outdated(installed: "0.9.1", bundled: "0.9.2"),
        onAction: {}
    )
    .frame(
        width: AgentStatusPopoverMetrics.contentSize(forStatus: .outdated(installed: "0.9.1", bundled: "0.9.2"), vmName: "Sequoia Dev").width,
        height: AgentStatusPopoverMetrics.contentSize(forStatus: .outdated(installed: "0.9.1", bundled: "0.9.2"), vmName: "Sequoia Dev").height
    )
}

#Preview("Popover — Current") {
    AgentStatusPopoverContent(
        vmName: "Sequoia Dev",
        status: .current(version: "0.9.2"),
        onAction: {}
    )
    .frame(
        width: AgentStatusPopoverMetrics.contentSize(forStatus: .current(version: "0.9.2"), vmName: "Sequoia Dev").width,
        height: AgentStatusPopoverMetrics.contentSize(forStatus: .current(version: "0.9.2"), vmName: "Sequoia Dev").height
    )
}

#Preview("Popover — Long VM name") {
    AgentStatusPopoverContent(
        vmName: "My Very Long macOS Sequoia Development VM Name",
        status: .outdated(installed: "0.9.1", bundled: "0.9.2"),
        onAction: {}
    )
    .frame(
        width: AgentStatusPopoverMetrics.contentSize(forStatus: .outdated(installed: "0.9.1", bundled: "0.9.2"), vmName: "My Very Long macOS Sequoia Development VM Name").width,
        height: AgentStatusPopoverMetrics.contentSize(forStatus: .outdated(installed: "0.9.1", bundled: "0.9.2"), vmName: "My Very Long macOS Sequoia Development VM Name").height
    )
}
