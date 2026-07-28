import AppKit
import Foundation
import Testing

@testable import Kernova

@Suite("CopyableCommandView Tests")
@MainActor
struct CopyableCommandViewTests {
    /// A private pasteboard so tests never disturb the user's clipboard.
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("kernova-test-\(UUID().uuidString)"))
    }

    private let command = "diskutil image create from --format ASIF '/tmp/a.dmg' '/tmp/a.asif'"

    @Test("Copying writes the command verbatim to the pasteboard")
    func copyWritesCommand() {
        let pasteboard = makePasteboard()
        let view = CopyableCommandView(command: command, pasteboard: pasteboard)

        view.copyCommand()

        #expect(pasteboard.string(forType: .string) == command)
    }

    @Test("Copying replaces prior pasteboard contents rather than appending")
    func copyClearsFirst() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("stale", forType: .string)
        let view = CopyableCommandView(command: command, pasteboard: pasteboard)

        view.copyCommand()

        #expect(pasteboard.string(forType: .string) == command)
    }

    @Test("The button confirms the copy")
    func copyConfirmsOnButton() {
        let view = CopyableCommandView(command: command, pasteboard: makePasteboard())
        #expect(view.copyButtonImageForTesting?.accessibilityDescription == "Copy command")

        view.copyCommand()

        #expect(view.copyButtonImageForTesting?.accessibilityDescription == "Command copied")
    }

    @Test("The view sizes itself, since NSAlert does not size its accessory")
    func viewHasConcreteFrame() {
        let view = CopyableCommandView(
            command: command, width: 340, pasteboard: makePasteboard())
        #expect(view.frame.width == 340)
        #expect(view.frame.height > 0)
    }
}
