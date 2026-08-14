import AppKit
import Testing

@testable import Kernova

@Suite("PortForwardingRuleSheetContentViewController Tests")
@MainActor
struct PortForwardingRuleSheetContentViewControllerTests {
    private func makeSheet(
        taken: Set<PortForwardingHostClaim> = []
    ) -> PortForwardingRuleSheetContentViewController {
        let vc = PortForwardingRuleSheetContentViewController(takenHostClaims: taken)
        vc.loadViewIfNeeded()
        return vc
    }

    private func field(
        _ identifier: NSUserInterfaceItemIdentifier,
        in vc: PortForwardingRuleSheetContentViewController
    ) -> NSTextField? {
        firstSubview(NSTextField.self, in: vc.view) { $0.identifier == identifier }
    }

    /// Types `text` into a field the way the user does — value plus the change
    /// notification the controller validates on.
    private func type(
        _ text: String, into identifier: NSUserInterfaceItemIdentifier,
        of vc: PortForwardingRuleSheetContentViewController
    ) throws {
        let field = try #require(self.field(identifier, in: vc))
        field.stringValue = text
        vc.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func addButton(in vc: PortForwardingRuleSheetContentViewController) -> NSButton? {
        findButton(titled: "Add", in: vc.view)
    }

    private func hostField(_ vc: PortForwardingRuleSheetContentViewController) -> NSTextField? {
        field(PortForwardingRuleSheetContentViewController.hostPortFieldIdentifier, in: vc)
    }

    @Test("Add is disabled until both ports are entered")
    func addDisabledUntilBothPorts() throws {
        let vc = makeSheet()
        #expect(addButton(in: vc)?.isEnabled == false)

        try type("80", into: .guestPort, of: vc)

        #expect(addButton(in: vc)?.isEnabled == true)
        #expect(vc.composedRule == PortForwardingRule(transport: .tcp, hostPort: 80, guestPort: 80))
    }

    @Test("The host port mirrors the guest port until the user gives it one")
    func hostPortMirrorsGuestPort() throws {
        let vc = makeSheet()

        try type("8", into: .guestPort, of: vc)
        try type("80", into: .guestPort, of: vc)
        #expect(hostField(vc)?.stringValue == "80")

        // Typing a host port of their own stops the mirroring.
        try type("8080", into: .hostPort, of: vc)
        try type("8080", into: .guestPort, of: vc)
        #expect(hostField(vc)?.stringValue == "8080")
        #expect(
            vc.composedRule == PortForwardingRule(transport: .tcp, hostPort: 8080, guestPort: 8080))
    }

    @Test("Zero, out-of-range, and non-numeric ports compose no rule")
    func invalidPortsComposeNoRule() throws {
        let vc = makeSheet()
        try type("80", into: .guestPort, of: vc)

        for text in ["0", "65536", "eighty", "-1", " "] {
            try type(text, into: .hostPort, of: vc)
            #expect(vc.composedRule == nil, "\(text) should compose no rule")
            #expect(addButton(in: vc)?.isEnabled == false)
        }

        try type("65535", into: .hostPort, of: vc)
        #expect(vc.composedRule?.hostPort == 65535)
    }

    @Test("A host port already forwarded is refused, and said so")
    func takenHostPortIsRefused() throws {
        let vc = makeSheet(taken: [PortForwardingHostClaim(transport: .tcp, hostPort: 8080)])

        try type("80", into: .guestPort, of: vc)
        try type("8080", into: .hostPort, of: vc)

        #expect(vc.composedRule == nil)
        #expect(addButton(in: vc)?.isEnabled == false)
        #expect(findLabel(containing: "already forwarded", in: vc.view) != nil)
    }

    @Test("The same host port on the other transport is free")
    func otherTransportIsNotACollision() throws {
        let vc = makeSheet(taken: [PortForwardingHostClaim(transport: .tcp, hostPort: 8080)])
        let popUp = try #require(firstSubview(NSPopUpButton.self, in: vc.view))

        try type("80", into: .guestPort, of: vc)
        try type("8080", into: .hostPort, of: vc)
        popUp.selectItem(withTitle: "UDP")
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(
            vc.composedRule == PortForwardingRule(transport: .udp, hostPort: 8080, guestPort: 80))
        #expect(addButton(in: vc)?.isEnabled == true)
    }

    @Test("A privileged host port is noted, not refused")
    func privilegedHostPortIsNoted() throws {
        let vc = makeSheet()

        try type("80", into: .guestPort, of: vc)
        try type("443", into: .hostPort, of: vc)

        #expect(addButton(in: vc)?.isEnabled == true)
        #expect(findLabel(containing: "reserved for system services", in: vc.view) != nil)

        try type("8443", into: .hostPort, of: vc)
        #expect(findLabel(containing: "reserved for system services", in: vc.view) == nil)
    }

    @Test("Add hands the composed rule to the delegate")
    func addReportsTheRule() throws {
        let vc = makeSheet()
        let delegate = MockPortForwardingRuleSheetDelegate()
        vc.delegate = delegate

        try type("22", into: .guestPort, of: vc)
        try type("2222", into: .hostPort, of: vc)
        addButton(in: vc)?.performClick(nil)

        #expect(delegate.added == [PortForwardingRule(transport: .tcp, hostPort: 2222, guestPort: 22)])
        #expect(delegate.cancelCount == 0)
    }

    @Test("Cancel reports a dismissal and no rule")
    func cancelReportsDismissal() {
        let vc = makeSheet()
        let delegate = MockPortForwardingRuleSheetDelegate()
        vc.delegate = delegate

        findButton(titled: "Cancel", in: vc.view)?.performClick(nil)

        #expect(delegate.added.isEmpty)
        #expect(delegate.cancelCount == 1)
    }
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let hostPort =
        PortForwardingRuleSheetContentViewController.hostPortFieldIdentifier
    fileprivate static let guestPort =
        PortForwardingRuleSheetContentViewController.guestPortFieldIdentifier
}

@MainActor
private final class MockPortForwardingRuleSheetDelegate:
    PortForwardingRuleSheetContentViewControllerDelegate
{
    private(set) var added: [PortForwardingRule] = []
    private(set) var cancelCount = 0

    func portForwardingRuleSheet(
        _ vc: PortForwardingRuleSheetContentViewController, didAdd rule: PortForwardingRule
    ) {
        added.append(rule)
    }

    func portForwardingRuleSheetDidCancel(_ vc: PortForwardingRuleSheetContentViewController) {
        cancelCount += 1
    }
}
