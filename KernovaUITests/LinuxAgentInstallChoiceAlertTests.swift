import AppKit
import Foundation
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// The radio group the Linux install question asks with, and the command it
/// shows and copies for the selected choice.
@Suite("Linux Agent Install Choice Alert Tests", .caseScoped)
@MainActor
struct LinuxAgentInstallChoiceAlertTests {
    @Test("The radios start on the initial choice, and selecting one shows and copies its command")
    func selectionDrivesTheCommand() throws {
        let viewModel = makeLibraryViewModel(preferences: makeTestPreferences())
        let vm = viewModel.library.admitFixture(name: "Ubuntu", guestOS: .linux)
        var copied: [String] = []
        let alert = LinuxAgentInstallChoiceAlert.configuration(
            for: vm, initial: .sessionAgent, configurations: AppAlertConfigurations(viewModel: viewModel),
            copy: { copied.append($0) })
        let view = try #require(alert.accessoryView as? LinuxAgentInstallChoiceView)

        #expect(view.radios.map(\.title) == LinuxAgentInstallChoice.allCases.map(\.title))
        #expect(view.radios.map(\.state) == [.off, .on, .off])
        #expect(view.commandLabel.stringValue == LinuxAgentDisk.installCommand(for: .sessionAgent))
        // Sized for the tallest choice before the sheet is built.
        #expect(view.frame.height > 0)

        view.radios[2].performClick(nil)
        #expect(view.choice == .systemService)
        #expect(view.radios.map(\.state) == [.off, .off, .on])
        #expect(view.commandLabel.stringValue == LinuxAgentDisk.installCommand(for: .systemService))
        #expect(view.headlessLabel.stringValue.hasSuffix("sudo sh /mnt/kernova-agent/install.sh --system"))

        alert.buttons.last?.action()
        #expect(copied.isEmpty)
        #expect(vm.configuration.removableMedia == nil)
    }
}
