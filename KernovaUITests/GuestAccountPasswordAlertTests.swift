import AppKit
import Foundation
import KernovaCommandModel
import Testing

@testable import KernovaCore
@testable import KernovaUI
@testable import KernovaVirtualization

/// What the resume prompt refuses before answering at all.
@Suite("Guest Account Password Alert", .caseScoped)
@MainActor
struct GuestAccountPasswordAlertTests {
    private final class Answers {
        var answered: [GuestAccountPasswordAnswer] = []
        var retries: [String] = []
    }

    private func makePrompt(fullName: String = "Ada Lovelace") -> GuestAccountPrompt {
        GuestAccountPrompt(
            vm: VMSummary(
                id: UUID(), name: "Sequoia", status: "stopped", ipAddress: .unavailable, heldByAnotherCopy: false),
            username: "ada", fullName: fullName,
            message: "\u{201C}Sequoia\u{201D} creates the macOS account.")
    }

    /// The sheet answers through the hook it is handed — the one-shot the
    /// presenter wraps the request's own in — so these drive that one.
    private func makeConfiguration(
        password: String, verification: String, answers: Answers,
        prompt: GuestAccountPrompt? = nil
    ) -> (SheetAlert, GuestAccountPasswordFields) {
        let fields = GuestAccountPasswordFields()
        fields.passwordField.stringValue = password
        fields.verifyField.stringValue = verification
        let configuration = GuestAccountPasswordAlert.configuration(
            prompt: prompt ?? makePrompt(), fields: fields, host: VirtualizationHost(),
            answer: { answers.answered.append($0) },
            retry: { answers.retries.append($0) })
        return (configuration, fields)
    }

    // MARK: - Refusals

    @Test("A verification that doesn't match is refused back to the sheet")
    func aMismatchGoesBackToTheSheet() throws {
        let answers = Answers()
        let (configuration, fields) = makeConfiguration(
            password: "analytical-engine", verification: "analytical engine", answers: answers)

        try #require(configuration.buttons.first).action()

        #expect(answers.retries == ["The passwords don\u{2019}t match."])
        #expect(answers.answered.isEmpty)
        // The refusal leaves what the user typed where they typed it, so the
        // sheet that comes back is the one they were already looking at.
        #expect(fields.password == "analytical-engine")
    }
}
