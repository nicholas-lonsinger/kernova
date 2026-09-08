import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// The one derivation of the `VZVirtualMachineView` properties a VM's display
/// carries, which both display hosts read.
@Suite("VMInstance display view settings", .admissionGated)
@MainActor
struct VMInstanceDisplayViewSettingsTests {
    private func makeInstance(
        systemKeyForwarding: VMSystemKeyForwarding = .always, displayAutoResizes: Bool = true
    ) -> VMInstance {
        let config = VMConfiguration(
            name: "Keys VM", guestOS: .macOS, bootMode: .macOS,
            displayAutoResizes: displayAutoResizes, systemKeyForwarding: systemKeyForwarding)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
    }

    @Test("Auto-resize is carried straight through")
    func autoResizeIsCarriedThrough() {
        #expect(
            makeInstance(displayAutoResizes: true).displayViewSettings
                .automaticallyReconfiguresDisplay)
        #expect(
            !makeInstance(displayAutoResizes: false).displayViewSettings
                .automaticallyReconfiguresDisplay)
    }

    @Test("Never and always ignore the display mode")
    func absoluteModesIgnoreDisplayMode() {
        for mode in [VMDisplayMode.inline, .popOut, .fullscreen, .hidden] {
            let never = makeInstance(systemKeyForwarding: .never)
            never.displayMode = mode
            #expect(!never.displayViewSettings.capturesSystemKeys, "\(mode)")

            let always = makeInstance(systemKeyForwarding: .always)
            always.displayMode = mode
            #expect(always.displayViewSettings.capturesSystemKeys, "\(mode)")
        }
    }

    @Test("Full-screen-only captures only in fullscreen")
    func fullscreenOnlyFollowsTheDisplayMode() {
        let instance = makeInstance(systemKeyForwarding: .fullscreenOnly)

        for mode in [VMDisplayMode.inline, .popOut, .hidden] {
            instance.displayMode = mode
            #expect(!instance.displayViewSettings.capturesSystemKeys, "\(mode)")
        }

        instance.displayMode = .fullscreen
        #expect(instance.displayViewSettings.capturesSystemKeys)
    }
}
