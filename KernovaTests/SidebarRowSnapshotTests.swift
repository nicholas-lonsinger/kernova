import AppKit
import Foundation
import Testing
@testable import Kernova

/// Field-correctness tests for ``VMInstance.sidebarRowSnapshot``.
///
/// The snapshot's `agentStatus` branches are covered separately by
/// ``VMInstanceVisibleAgentStatusTests`` via the static
/// `computeVisibleSidebarAgentStatus` decision function; these tests focus
/// on the other five fields (name, iconName, subtitle, toolTip,
/// statusColor) and the `isSpinning` predicate across representative VM
/// states.
@Suite("SidebarRowSnapshot")
@MainActor
struct SidebarRowSnapshotTests {
    private func makeInstance(
        name: String = "Test VM",
        guestOS: VMGuestOS = .linux,
        status: VMStatus = .stopped
    ) -> VMInstance {
        let config = VMConfiguration(name: name, guestOS: guestOS, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL, status: status)
    }

    // MARK: - Name / icon / subtitle

    @Test("Linux VM snapshot exposes name + terminal icon + Linux subtitle")
    func linuxFields() {
        let snapshot = makeInstance(name: "Ubuntu", guestOS: .linux).sidebarRowSnapshot
        #expect(snapshot.name == "Ubuntu")
        #expect(snapshot.iconName == "terminal.fill")
        #expect(snapshot.subtitle == "Linux")
    }

    @Test("macOS VM snapshot exposes Apple logo + macOS subtitle")
    func macOSFields() {
        let snapshot = makeInstance(name: "Sequoia", guestOS: .macOS).sidebarRowSnapshot
        #expect(snapshot.name == "Sequoia")
        #expect(snapshot.iconName == "apple.logo")
        #expect(snapshot.subtitle == "macOS")
    }

    // MARK: - Status color

    @Test("Stopped status maps to secondary label color")
    func stoppedColor() {
        let snapshot = makeInstance(status: .stopped).sidebarRowSnapshot
        #expect(snapshot.statusColor == NSColor.secondaryLabelColor)
    }

    @Test("Running status maps to systemGreen")
    func runningColor() {
        let snapshot = makeInstance(status: .running).sidebarRowSnapshot
        #expect(snapshot.statusColor == NSColor.systemGreen)
    }

    @Test("Cold-paused status maps to systemOrange (paused with no live VM)")
    func coldPausedColor() {
        // Test VMInstance has no VZVirtualMachine, so `status == .paused`
        // means cold-paused; statusDisplayColor overrides to orange.
        let snapshot = makeInstance(status: .paused).sidebarRowSnapshot
        #expect(snapshot.statusColor == NSColor.systemOrange)
    }

    @Test("Error status maps to systemRed")
    func errorColor() {
        let snapshot = makeInstance(status: .error).sidebarRowSnapshot
        #expect(snapshot.statusColor == NSColor.systemRed)
    }

    @Test("Initial-boot status maps to systemOrange")
    func initialBootColor() {
        let snapshot = makeInstance(status: .initialBoot).sidebarRowSnapshot
        #expect(snapshot.statusColor == NSColor.systemOrange)
    }

    // MARK: - isSpinning

    @Test("Stopped VM does not spin")
    func stoppedDoesNotSpin() {
        #expect(makeInstance(status: .stopped).sidebarRowSnapshot.isSpinning == false)
    }

    @Test("Running VM does not spin")
    func runningDoesNotSpin() {
        #expect(makeInstance(status: .running).sidebarRowSnapshot.isSpinning == false)
    }

    @Test("Transitioning statuses spin (.starting / .saving / .restoring / .installing)")
    func transitioningSpins() {
        // `.initialBoot` is colored as a transition but doesn't spin —
        // the install hasn't started yet so the row stays static.
        for status: VMStatus in [.starting, .saving, .restoring, .installing] {
            let snapshot = makeInstance(status: status).sidebarRowSnapshot
            #expect(snapshot.isSpinning == true, "expected \(status) to spin")
        }
    }

    @Test("Initial-boot status does not spin")
    func initialBootDoesNotSpin() {
        #expect(makeInstance(status: .initialBoot).sidebarRowSnapshot.isSpinning == false)
    }

    // MARK: - Tooltip

    @Test("Stopped VM has no tooltip")
    func stoppedTooltipNil() {
        #expect(makeInstance(status: .stopped).sidebarRowSnapshot.toolTip == nil)
    }

    @Test("Initial-boot VM tooltip prompts the user to start the install")
    func initialBootTooltip() {
        let snapshot = makeInstance(status: .initialBoot).sidebarRowSnapshot
        #expect(snapshot.toolTip == "Click Start to install macOS")
    }

    @Test("Cold-paused VM tooltip says 'saved to disk'")
    func coldPausedTooltip() {
        // Test instance has no live VZVirtualMachine, so .paused = cold-paused.
        let snapshot = makeInstance(status: .paused).sidebarRowSnapshot
        #expect(snapshot.toolTip == "VM state is saved to disk")
    }
}
