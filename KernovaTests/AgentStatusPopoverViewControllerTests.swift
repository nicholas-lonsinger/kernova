import AppKit
import Foundation
import Testing
@testable import Kernova

@Suite("AgentStatusPopoverViewController Tests")
@MainActor
struct AgentStatusPopoverViewControllerTests {
    private func findField(in view: NSView, identifier: String) -> NSTextField? {
        for subview in view.subviews {
            if subview.identifier?.rawValue == identifier, let field = subview as? NSTextField {
                return field
            }
            if let nested = findField(in: subview, identifier: identifier) {
                return nested
            }
        }
        return nil
    }

    private func findButton(in view: NSView, identifier: String) -> NSButton? {
        for subview in view.subviews {
            if subview.identifier?.rawValue == identifier, let button = subview as? NSButton {
                return button
            }
            if let nested = findButton(in: subview, identifier: identifier) {
                return nested
            }
        }
        return nil
    }

    @Test("Title field carries the status-specific headline")
    func titleField() {
        let vc = AgentStatusPopoverViewController(
            status: .outdated(installed: "0.9", bundled: "1.0"),
            vmName: "Sequoia Dev",
            onAction: {},
            onDismiss: nil
        )
        _ = vc.view  // load
        let title = findField(in: vc.view, identifier: "AgentPopover.Title")
        #expect(title?.stringValue == "Update available")
    }

    @Test("Body field text is wrapped via preferredMaxLayoutWidth and contains the vmName")
    func bodyField() {
        let vc = AgentStatusPopoverViewController(
            status: .waiting,
            vmName: "Sequoia Dev",
            onAction: {},
            onDismiss: nil
        )
        _ = vc.view
        let body = findField(in: vc.view, identifier: "AgentPopover.Body")
        #expect(body?.stringValue.contains("Sequoia Dev") == true)
        #expect(body?.maximumNumberOfLines == 0)
        // preferredMaxLayoutWidth seeds word wrapping; the popover's
        // actual width comes from fittingSize at layout time.
        #expect((body?.preferredMaxLayoutWidth ?? 0) > 0)
    }

    @Test("Popover sizes to content via fittingSize after layout")
    func popoverSizesNaturally() {
        let vc = AgentStatusPopoverViewController(
            status: .waiting,
            vmName: "Sequoia Dev",
            onAction: {},
            onDismiss: nil
        )
        _ = vc.view
        vc.view.layoutSubtreeIfNeeded()
        vc.viewDidLayout()
        // Width and height are picked up from fittingSize; both must be
        // positive or the popover would render as a zero-sized rect.
        #expect(vc.preferredContentSize.width > 0)
        #expect(vc.preferredContentSize.height > 0)
    }

    @Test("Action button title reflects status")
    func actionButtonTitleMatchesStatus() {
        let vc = AgentStatusPopoverViewController(
            status: .expectedMissing(expected: "1.0"),
            vmName: "Sequoia Dev",
            onAction: {},
            onDismiss: nil
        )
        _ = vc.view
        let action = findButton(in: vc.view, identifier: "AgentPopover.Action")
        #expect(action?.title == "Reinstall Guest Agent\u{2026}")
        // Default-action: Return invokes it
        #expect(action?.keyEquivalent == "\r")
    }

    @Test("Action button invokes onAction closure")
    func actionInvokesClosure() {
        var fired = false
        let vc = AgentStatusPopoverViewController(
            status: .waiting,
            vmName: "Sequoia Dev",
            onAction: { fired = true },
            onDismiss: nil
        )
        _ = vc.view
        let action = findButton(in: vc.view, identifier: "AgentPopover.Action")
        action?.performClick(nil)
        #expect(fired == true)
    }

    @Test("Dismiss button appears only when onDismiss is supplied")
    func dismissButtonPresenceGatedByCallback() {
        let withDismiss = AgentStatusPopoverViewController(
            status: .waiting,
            vmName: "Sequoia Dev",
            onAction: {},
            onDismiss: {}
        )
        _ = withDismiss.view
        #expect(findButton(in: withDismiss.view, identifier: "AgentPopover.Dismiss") != nil)

        let withoutDismiss = AgentStatusPopoverViewController(
            status: .waiting,
            vmName: "Sequoia Dev",
            onAction: {},
            onDismiss: nil
        )
        _ = withoutDismiss.view
        #expect(findButton(in: withoutDismiss.view, identifier: "AgentPopover.Dismiss") == nil)
    }

    @Test("Dismiss button invokes onDismiss closure")
    func dismissInvokesClosure() {
        var fired = false
        let vc = AgentStatusPopoverViewController(
            status: .waiting,
            vmName: "Sequoia Dev",
            onAction: {},
            onDismiss: { fired = true }
        )
        _ = vc.view
        let dismiss = findButton(in: vc.view, identifier: "AgentPopover.Dismiss")
        dismiss?.performClick(nil)
        #expect(fired == true)
    }
}
