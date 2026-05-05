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
/// ## Why this uses NSPopover with an explicit contentSize and AppKit text
/// On macOS Tahoe, SwiftUI's `Text` does not reliably wrap inside an
/// `NSHostingController` even with explicit `.frame(width:)` constraints —
/// it renders single-line at its ideal width and overflows. The popover
/// therefore:
///   1. Pre-measures the body text with `NSAttributedString.boundingRect`
///      and pins both `popover.contentSize` and the SwiftUI outer frame to
///      that exact (width, height).
///   2. Renders the wrapping body via `WrappingNSTextLabel`
///      (`NSTextField(wrappingLabelWithString:)` bridged through
///      `NSViewRepresentable`), which honors `preferredMaxLayoutWidth` and
///      wraps reliably regardless of how SwiftUI propagates proposals.
struct SidebarAgentStatusButton: View {
    let vmName: String
    let status: AgentStatus
    let onMount: () -> Void
    /// Optional opt-out callback. Wired only for `.waiting` — the other
    /// states (`.outdated`, `.unresponsive`, `.expectedMissing`) are not
    /// dismissable because they imply something more urgent than "you could
    /// install this."
    let onDismiss: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            Image(systemName: symbolName)
                .foregroundStyle(symbolColor)
                .font(.system(size: 12, weight: .semibold))
                // Spin the refresh symbol while we're in the post-start
                // grace window for a previously-installed agent. The
                // rotation stops automatically once `.connecting` resolves
                // to `.current` (icon hidden) or `.expectedMissing` (icon
                // becomes the warning triangle). Gated on
                // `accessibilityReduceMotion` so users who've disabled
                // motion in System Settings see a static icon — the gray
                // color (vs. orange `.outdated`) still differentiates the
                // state, and the popover/help text carry the meaning.
                .symbolEffect(
                    .rotate,
                    options: .repeat(.continuous),
                    isActive: status.isConnecting && !reduceMotion
                )
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
                        switch status {
                        case .current, .unresponsive, .connecting:
                            // Done — just close. Nothing to install or update;
                            // an unresponsive agent will reset itself once the
                            // heartbeat timeout fires, and a connecting agent
                            // is already on the way.
                            break
                        case .waiting, .outdated, .expectedMissing:
                            onMount()
                        }
                        isPopoverPresented = false
                    },
                    onDismiss: onDismiss.map { dismiss in
                        {
                            dismiss()
                            isPopoverPresented = false
                        }
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
        // Same refresh symbol as `.outdated`; a continuous-rotation
        // `.symbolEffect` distinguishes "actively trying to connect" from
        // "stationary update available."
        case .connecting: "arrow.triangle.2.circlepath.circle.fill"
        case .current: "checkmark.circle.fill"
        case .unresponsive: "wifi.exclamationmark"
        // Triangle (vs the .waiting circle) signals "something went wrong"
        // rather than "still pending" — the agent was here before, and didn't
        // come back this boot.
        case .expectedMissing: "exclamationmark.triangle.fill"
        }
    }

    private var symbolColor: Color {
        switch status {
        case .waiting: .secondary
        case .outdated: .orange
        // Gray (not orange) — `.connecting` is informational, not an
        // attention state. The rotation animation carries the "in
        // progress" signal.
        case .connecting: .secondary
        case .current: .green
        case .unresponsive: .orange
        case .expectedMissing: .orange
        }
    }

    private var helpText: String {
        switch status {
        case .waiting: "Guest agent not installed"
        case .outdated(let installed, let bundled): "Guest agent update available (\(installed) → \(bundled))"
        case .connecting(let expected): "Connecting to guest agent (was \(expected))"
        case .current(let version): "Guest agent connected (\(version))"
        case .unresponsive(let version): "Guest agent unresponsive (\(version))"
        case .expectedMissing(let expected): "Guest agent didn't reconnect (was \(expected))"
        }
    }
}

// MARK: - Popover content & metrics

/// Body of the agent-status popover. The wrapping body text is rendered
/// via `WrappingNSTextLabel` (an AppKit `NSTextField` wrapping label) because
/// SwiftUI `Text` does not reliably wrap inside `NSHostingController` on
/// macOS Tahoe even with explicit `.frame(width:)` and `.fixedSize(...)`.
struct AgentStatusPopoverContent: View {
    let vmName: String
    let status: AgentStatus
    let onAction: () -> Void
    /// When non-nil, a "Don't show again" button is rendered at the
    /// bottom-leading edge of the action row.
    let onDismiss: (() -> Void)?

    var body: some View {
        let bodyWidth = AgentStatusPopoverMetrics.contentWidth
            - AgentStatusPopoverMetrics.padding * 2
        let size = AgentStatusPopoverMetrics.contentSize(forStatus: status, vmName: vmName)

        VStack(alignment: .leading, spacing: AgentStatusPopoverMetrics.verticalSpacing) {
            Text(AgentStatusPopoverMetrics.title(for: status))
                .font(.headline)
                .frame(width: bodyWidth, alignment: .leading)

            WrappingNSTextLabel(
                text: AgentStatusPopoverMetrics.bodyText(for: status, vmName: vmName),
                font: .preferredFont(forTextStyle: .callout),
                textColor: .secondaryLabelColor,
                maxWidth: bodyWidth
            )
            .frame(width: bodyWidth, alignment: .leading)

            HStack {
                if let onDismiss {
                    Button("Don't show again", action: onDismiss)
                        .buttonStyle(.link)
                }
                Spacer()
                Button(buttonTitle, action: onAction)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(width: bodyWidth)
        }
        .padding(AgentStatusPopoverMetrics.padding)
        // Pin both width and height to the pre-measured contentSize so the
        // SwiftUI view exactly fills the popover. Without an explicit height,
        // SwiftUI's ideal height could fall below the popover's contentSize
        // and NSHostingController would float the content inside the
        // popover, clipping the title at the top edge.
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private var buttonTitle: String {
        switch status {
        case .waiting: "Install Guest Agent…"
        case .outdated: "Update Guest Agent…"
        case .current, .unresponsive, .connecting: "Done"
        case .expectedMissing: "Reinstall Guest Agent…"
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

    /// Line height of the `.headline` font as currently configured. Reading
    /// from `NSFont.preferredFont` honors the user's Dynamic Type setting, so
    /// the popover height stays correct under accessibility text scaling.
    /// `descender` is negative on macOS, so subtracting it adds the descent
    /// portion to the total height.
    private static var titleLineHeight: CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .headline)
        return ceil(font.ascender - font.descender + font.leading)
    }

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
        case .connecting: "Connecting to guest agent"
        case .current: "Guest agent connected"
        case .unresponsive: "Guest agent unresponsive"
        case .expectedMissing: "Guest agent didn't reconnect"
        }
    }

    static func bodyText(for status: AgentStatus, vmName: String) -> String {
        switch status {
        case .waiting:
            return "The Kernova guest agent enables clipboard sync with \(vmName). Mounting the installer presents it as a disk inside the VM — open it in Finder and run install.command."
        case .outdated(let installed, let bundled):
            return "\(vmName) is running guest agent \(installed). Kernova bundles \(bundled). Mounting the installer presents it as a disk inside the VM — open it in Finder and run install.command."
        case .connecting(let expected):
            return "Waiting for guest agent \(expected) on \(vmName) to reconnect after boot. If it doesn't connect within a couple of minutes, you'll see a 'didn't reconnect' indicator with reinstall steps."
        case .current(let version):
            return "\(vmName) is connected with guest agent \(version)."
        case .unresponsive(let version):
            return "\(vmName) (guest agent \(version)) stopped responding to heartbeats. The control connection will reset automatically; if it persists, restart the agent inside the VM."
        case .expectedMissing(let expected):
            return "\(vmName) had guest agent \(expected) installed previously, but it didn't connect after this boot. The agent's LaunchAgent may be unloaded, or it may have been uninstalled inside the VM. Reinstalling presents the installer as a disk — open it in Finder and run install.command."
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
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isPresented {
            context.coordinator.showOrUpdate(
                content: content(),
                contentSize: contentSize,
                from: nsView,
                preferredEdge: preferredEdge
            )
        } else {
            context.coordinator.close()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        let isPresented: Binding<Bool>
        private var popover: NSPopover?

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
        }

        func showOrUpdate<C: View>(
            content: C,
            contentSize: NSSize,
            from anchor: NSView,
            preferredEdge: NSRectEdge
        ) {
            // If a popover is already shown, refresh its content + size in place
            // instead of dismissing/re-presenting (which would flicker). This
            // keeps the popover reactive when `status` or `vmName` changes
            // while it's open — e.g. the agent connects mid-popover and the
            // status flips from .waiting to .current.
            if let popover, popover.isShown,
               let hostingController = popover.contentViewController as? NSHostingController<C> {
                hostingController.rootView = content
                hostingController.preferredContentSize = contentSize
                popover.contentSize = contentSize
                return
            }

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

// MARK: - Wrapping text label

/// AppKit-backed multi-line wrapping label. SwiftUI's `Text` doesn't
/// reliably wrap inside an `NSHostingController` on macOS Tahoe (it renders
/// single-line at its ideal width and overflows), so the popover renders
/// the wrapping body string through `NSTextField(wrappingLabelWithString:)`
/// instead. AppKit's `preferredMaxLayoutWidth` property does what
/// SwiftUI's `.frame(width:)` should: caps the line width and produces a
/// correct intrinsic content size for the wrapped layout.
struct WrappingNSTextLabel: NSViewRepresentable {
    let text: String
    let font: NSFont
    let textColor: NSColor
    let maxWidth: CGFloat

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = textColor
        field.preferredMaxLayoutWidth = maxWidth
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // Guard `stringValue` and `preferredMaxLayoutWidth` because they
        // trigger layout invalidation when set; `font` and `textColor` are
        // unconditionally assigned because their `!=` comparison uses
        // pointer equality on `NSColor` / `NSFont`, and dynamic system
        // colors (e.g. `.secondaryLabelColor` adapts to dark mode) can
        // resolve to the same pointer across appearance changes — the
        // guard would skip a needed update.
        if nsView.stringValue != text { nsView.stringValue = text }
        nsView.font = font
        nsView.textColor = textColor
        if nsView.preferredMaxLayoutWidth != maxWidth {
            nsView.preferredMaxLayoutWidth = maxWidth
        }
        // Notify the layout system that the intrinsic size may have
        // changed (text/font/maxWidth all affect it). The current popover
        // pins its outer frame to a pre-measured size and ignores the
        // intrinsic value, so this is effectively a no-op there — but it
        // keeps the component correct if reused in a flexible container.
        nsView.invalidateIntrinsicContentSize()
    }
}

// MARK: - Previews

// Sidebar button + click target. Click the icon to open the live popover.
#Preview("Button — Waiting") {
    SidebarAgentStatusButton(
        vmName: "Sequoia Dev",
        status: .waiting,
        onMount: {},
        onDismiss: {}
    )
    .padding(40)
}

#Preview("Button — Outdated") {
    SidebarAgentStatusButton(
        vmName: "Sequoia Dev",
        status: .outdated(installed: "0.9.1", bundled: "0.9.2"),
        onMount: {},
        onDismiss: nil
    )
    .padding(40)
}

#Preview("Button — Current") {
    SidebarAgentStatusButton(
        vmName: "Sequoia Dev",
        status: .current(version: "0.9.2"),
        onMount: {},
        onDismiss: nil
    )
    .padding(40)
}

#Preview("Button — Unresponsive") {
    SidebarAgentStatusButton(
        vmName: "Sequoia Dev",
        status: .unresponsive(version: "0.9.2"),
        onMount: {},
        onDismiss: nil
    )
    .padding(40)
}

#Preview("Button — ExpectedMissing") {
    SidebarAgentStatusButton(
        vmName: "Sequoia Dev",
        status: .expectedMissing(expected: "0.9.2"),
        onMount: {},
        onDismiss: nil
    )
    .padding(40)
}

// Standalone popover content rendered in a fixed frame matching the actual
// popover content size, so the canvas mirrors what NSPopover will display.
#Preview("Popover — Waiting") {
    AgentStatusPopoverContent(
        vmName: "Sequoia Dev",
        status: .waiting,
        onAction: {},
        onDismiss: {}
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
        onAction: {},
        onDismiss: nil
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
        onAction: {},
        onDismiss: nil
    )
    .frame(
        width: AgentStatusPopoverMetrics.contentSize(forStatus: .current(version: "0.9.2"), vmName: "Sequoia Dev").width,
        height: AgentStatusPopoverMetrics.contentSize(forStatus: .current(version: "0.9.2"), vmName: "Sequoia Dev").height
    )
}

#Preview("Popover — ExpectedMissing") {
    AgentStatusPopoverContent(
        vmName: "Sequoia Dev",
        status: .expectedMissing(expected: "0.9.2"),
        onAction: {},
        onDismiss: nil
    )
    .frame(
        width: AgentStatusPopoverMetrics.contentSize(forStatus: .expectedMissing(expected: "0.9.2"), vmName: "Sequoia Dev").width,
        height: AgentStatusPopoverMetrics.contentSize(forStatus: .expectedMissing(expected: "0.9.2"), vmName: "Sequoia Dev").height
    )
}

#Preview("Popover — Long VM name") {
    AgentStatusPopoverContent(
        vmName: "My Very Long macOS Sequoia Development VM Name",
        status: .outdated(installed: "0.9.1", bundled: "0.9.2"),
        onAction: {},
        onDismiss: nil
    )
    .frame(
        width: AgentStatusPopoverMetrics.contentSize(forStatus: .outdated(installed: "0.9.1", bundled: "0.9.2"), vmName: "My Very Long macOS Sequoia Development VM Name").width,
        height: AgentStatusPopoverMetrics.contentSize(forStatus: .outdated(installed: "0.9.1", bundled: "0.9.2"), vmName: "My Very Long macOS Sequoia Development VM Name").height
    )
}
