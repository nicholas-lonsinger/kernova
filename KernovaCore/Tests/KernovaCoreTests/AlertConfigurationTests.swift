import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore

/// Covers `AlertConfiguration` — the buttons an alert offers and the roles
/// that lay them out.
@Suite("AlertConfiguration", .caseScoped)
struct AlertConfigurationTests {
    // MARK: - init(confirming:)

    /// A confirmation whose confirm destroys something and whose alternative is
    /// the gentler route — the force-stop shape.
    private func destructiveConfirmPrompt() -> ConfirmationPrompt {
        ConfirmationPrompt(
            kind: .forceStop, title: "Force Stop \u{201C}VM\u{201D}?",
            message: "Anything in the guest that isn\u{2019}t saved to disk will be lost.",
            confirmTitle: "Force Stop", dismissTitle: "Cancel",
            alternatives: [ConfirmationAlternative(title: "Stop", disposition: .graceful)])
    }

    @Test("A destructive confirm with no alternative leads, and no button takes Return")
    func confirmingDestructiveAlone() {
        let prompt = ConfirmationPrompt(
            kind: .deleteSnapshot, title: "Delete \u{201C}Before\u{201D}?",
            message: "Its files go to the Trash.", confirmTitle: "Delete", dismissTitle: "Cancel")

        let config = AlertConfiguration(confirming: prompt, confirm: {})

        #expect(config.buttons.map(\.title) == ["Delete", "Cancel"])
        #expect(config.buttons.map(\.role) == [.destructive, .cancel])
        #expect(!config.buttons.contains { $0.role == .default })
    }

    @Test("Each button reaches its own handler, alternatives carrying which one was picked")
    func confirmingRoutesEachButton() {
        var confirmed = 0
        var dismissed = 0
        var chosen: [ConfirmationAlternative] = []
        let prompt = destructiveConfirmPrompt()
        let config = AlertConfiguration(
            confirming: prompt,
            confirm: { confirmed += 1 },
            alternative: { chosen.append($0) },
            dismiss: { dismissed += 1 })

        for button in config.buttons { button.action() }

        #expect(confirmed == 1)
        #expect(dismissed == 1)
        #expect(chosen == prompt.alternatives)
    }

    // MARK: - acknowledgement

    @Test("An acknowledgement is one OK button on Return")
    func acknowledgementIsASingleDefaultOK() {
        let config = AlertConfiguration.acknowledgement(title: "Error", message: "It failed.")

        #expect(config.title == "Error")
        #expect(config.message == "It failed.")
        #expect(config.buttons.map(\.title) == ["OK"])
        #expect(config.buttons.map(\.role) == [.default])
    }
}
