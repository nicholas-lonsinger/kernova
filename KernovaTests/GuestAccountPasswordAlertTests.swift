import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// What the resume prompt says, what each of its three buttons answers with,
/// and what it refuses before answering at all.
///
/// Nothing here asserts what Virtualization *accepts* — the two checks this
/// owns are the form's (a blank field, a mismatch), and the framework's verdict
/// is passed through as written.
@Suite("Guest Account Password Alert", .admissionGated)
@MainActor
struct GuestAccountPasswordAlertTests {
    private final class Answers {
        var answered: [GuestAccountPasswordAnswer] = []
        var retries: [String] = []
    }

    private func makePrompt(fullName: String = "Ada Lovelace") -> GuestAccountPrompt {
        GuestAccountPrompt(
            vm: VMSummary(
                id: UUID(), name: "Sequoia", status: "stopped", ipAddress: .unavailable),
            username: "ada", fullName: fullName,
            message: "\u{201C}Sequoia\u{201D} creates the macOS account.")
    }

    /// The sheet answers through the hook it is handed — the one-shot the
    /// presenter wraps the request's own in — so these drive that one.
    private func makeConfiguration(
        password: String, verification: String, answers: Answers,
        prompt: GuestAccountPrompt? = nil
    ) -> (AlertConfiguration, GuestAccountPasswordFields) {
        let fields = GuestAccountPasswordFields()
        fields.passwordField.stringValue = password
        fields.verifyField.stringValue = verification
        let configuration = GuestAccountPasswordAlert.configuration(
            prompt: prompt ?? makePrompt(), fields: fields,
            answer: { answers.answered.append($0) },
            retry: { answers.retries.append($0) })
        return (configuration, fields)
    }

    // MARK: - Copy

    @Test("The prompt names the account, and the message names the VM")
    func copyNamesTheAccountAndTheVM() {
        let answers = Answers()
        let (configuration, _) = makeConfiguration(
            password: "analytical-engine", verification: "analytical-engine", answers: answers)

        // Both halves of the account's name, the way the `kernova` tool's own
        // refusal spells it.
        #expect(
            configuration.title == "Enter the Password for \u{201C}Ada Lovelace\u{201D} (ada)")
        #expect(
            configuration.message
                == "Kernova doesn\u{2019}t save the password for the account it creates on "
                + "\u{201C}Sequoia\u{201D}, so this start needs it again. Skip setup "
                + "and macOS asks for an account in Setup Assistant instead.")
    }

    @Test("The sheet opens with the password field focused")
    func theSheetFocusesThePasswordField() {
        let answers = Answers()
        let (configuration, fields) = makeConfiguration(
            password: "", verification: "", answers: answers)

        #expect(configuration.accessoryView === fields)
        #expect(configuration.initialFirstResponder === fields.passwordField)
    }

    // MARK: - Buttons

    @Test("Three buttons, one Return, and Escape on the one that starts nothing")
    func buttonsAreOrderedForTheirAnswers() {
        let answers = Answers()
        let (configuration, _) = makeConfiguration(
            password: "analytical-engine", verification: "analytical-engine", answers: answers)

        #expect(configuration.buttons.map(\.title) == ["Set Up Account", "Skip Setup", "Cancel"])
        #expect(configuration.buttons.filter { $0.role == .default }.count == 1)
        #expect(configuration.buttons.first?.role == .default)
        #expect(configuration.buttons.last?.role == .cancel)
    }

    @Test("Set Up Account answers with the typed password")
    func setUpAccountAnswersWithThePassword() throws {
        let answers = Answers()
        let (configuration, _) = makeConfiguration(
            password: "analytical-engine", verification: "analytical-engine", answers: answers)

        try #require(configuration.buttons.first).action()

        #expect(answers.answered == [.answered(.password("analytical-engine"))])
        #expect(answers.retries.isEmpty)
    }

    @Test("Skip Setup answers with a start that creates no account")
    func skipSetupAnswersSkip() throws {
        let answers = Answers()
        let (configuration, _) = makeConfiguration(
            password: "analytical-engine", verification: "analytical-engine", answers: answers)

        configuration.buttons[1].action()

        #expect(answers.answered == [.answered(.skip)])
    }

    @Test("Cancel answers with no start at all")
    func cancelAnswersCancelled() throws {
        let answers = Answers()
        let (configuration, _) = makeConfiguration(
            password: "analytical-engine", verification: "analytical-engine", answers: answers)

        try #require(configuration.buttons.last).action()

        #expect(answers.answered == [.cancelled])
    }

    // MARK: - Refusals

    @Test("An empty field is refused back to the sheet rather than answered")
    func anEmptyFieldGoesBackToTheSheet() throws {
        let answers = Answers()
        let (configuration, _) = makeConfiguration(password: "", verification: "", answers: answers)

        try #require(configuration.buttons.first).action()

        #expect(answers.retries == ["Enter the password to continue."])
        #expect(answers.answered.isEmpty)
    }

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

    @available(macOS 27.0, *)
    @Test("A field this sheet cannot show is not the user's to fill in")
    func aFieldTheSheetCannotShowIsNotRefusedAsUnfinished() throws {
        let answers = Answers()
        // An account whose full name is blank: this sheet has no control for
        // it, so "enter the password" would refuse a password that is already
        // there every time it is clicked.
        let (configuration, _) = makeConfiguration(
            password: "analytical-engine", verification: "analytical-engine", answers: answers,
            prompt: makePrompt(fullName: ""))

        try #require(configuration.buttons.first).action()

        let refusal = try #require(answers.retries.first)
        #expect(refusal != "Enter the password to continue.")
        #expect(answers.answered.isEmpty)
    }

    @Test("Showing a refusal leaves room for it, and taking it away gives the room back")
    func aShownRefusalResizesTheAccessoryView() {
        let fields = GuestAccountPasswordFields()
        let plainHeight = fields.frame.height

        fields.show(refusal: "The passwords don\u{2019}t match.")
        let refusedHeight = fields.frame.height
        fields.show(refusal: nil)

        // An `NSAlert` lays its accessory view out from the frame the view
        // arrives with, so the refusal has to be in that frame before the sheet
        // is built.
        #expect(refusedHeight > plainHeight)
        #expect(fields.frame.height == plainHeight)
    }

    // MARK: - Redaction

    @Test("Describing an answer redacts the password it carries")
    func describingAnAnswerRedactsThePassword() {
        let description = String(
            describing: GuestAccountPasswordAnswer.answered(
                .password("correct-horse-battery-staple")))
        #expect(!description.contains("correct-horse-battery-staple"))
        #expect(description.contains("<redacted>"))
    }
}
