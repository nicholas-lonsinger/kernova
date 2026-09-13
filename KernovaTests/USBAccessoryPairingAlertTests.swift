import AppKit
import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// What the prompt says, and what each of its buttons answers with.
@Suite("USB Accessory Pairing Alert Tests", .admissionGated)
@MainActor
struct USBAccessoryPairingAlertTests {
    private func makeInstance(named name: String) -> VMInstance {
        let config = VMConfiguration(name: name, guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
    }

    private final class Answer {
        var answered: [VMInstance?] = []
    }

    private func makeRequest(candidates: [VMInstance], answer: Answer)
        -> USBAccessoryPairingRequest
    {
        USBAccessoryPairingRequest(
            id: UUID(),
            accessory: USBAccessorySummary(
                registryID: 7, name: "Samsung Type-C", vendorID: 0x04E8, productID: 0x6300),
            candidates: candidates,
            answer: { answer.answered.append($0) })
    }

    private func chooser(in configuration: AlertConfiguration) -> NSPopUpButton? {
        (configuration.accessoryView as? NSStackView)?
            .arrangedSubviews
            .compactMap { $0 as? NSPopUpButton }
            .first
    }

    @Test("One running guest is named in the question, with nothing to choose")
    func oneCandidateNamesTheVM() {
        let answer = Answer()
        let request = makeRequest(candidates: [makeInstance(named: "Work")], answer: answer)

        let configuration = USBAccessoryPairingAlert.configuration(for: request)

        #expect(configuration.title == "Pass \u{201C}Samsung Type-C\u{201D} through to \u{201C}Work\u{201D}?")
        #expect(
            configuration.message
                == "While \u{201C}Work\u{201D} holds this accessory, macOS cannot use it. Kernova will pass it through to \u{201C}Work\u{201D} again whenever both are available."
        )
        #expect(configuration.accessoryView == nil)
    }

    @Test("Several running guests name none, and are offered in a popup")
    func severalCandidatesOfferAChooser() throws {
        let answer = Answer()
        let request = makeRequest(
            candidates: [makeInstance(named: "Work"), makeInstance(named: "Play")], answer: answer)

        let configuration = USBAccessoryPairingAlert.configuration(for: request)

        #expect(configuration.title == "Pass \u{201C}Samsung Type-C\u{201D} through to a virtual machine?")
        let popUp = try #require(chooser(in: configuration))
        #expect(popUp.itemTitles == ["Work", "Play"])
    }

    @Test("Both shapes offer the same two buttons, and exactly one Return")
    func buttonsAreTheSameInBothShapes() {
        let answer = Answer()
        for count in 1...2 {
            let candidates = (0..<count).map { makeInstance(named: "VM \($0)") }
            let configuration = USBAccessoryPairingAlert.configuration(
                for: makeRequest(candidates: candidates, answer: answer))

            #expect(configuration.buttons.map(\.title) == ["Pass Through", "Keep on Mac"], "\(count)")
            // The trailing edge — the first listed — is the action, and Escape
            // leaves the accessory where it already is.
            #expect(configuration.buttons.filter { $0.role == .default }.count == 1, "\(count)")
            #expect(configuration.buttons.last?.role == .cancel, "\(count)")
        }
    }

    @Test("Keep on Mac answers with no virtual machine")
    func keepOnMacAnswersWithNothing() throws {
        let answer = Answer()
        let configuration = USBAccessoryPairingAlert.configuration(
            for: makeRequest(candidates: [makeInstance(named: "Work")], answer: answer))

        try #require(configuration.buttons.last).action()

        #expect(answer.answered.count == 1)
        #expect(answer.answered[0] == nil)
    }

    @Test("Pass Through answers with the one candidate when there is only one")
    func passThroughAnswersWithTheLoneCandidate() throws {
        let answer = Answer()
        let work = makeInstance(named: "Work")
        let configuration = USBAccessoryPairingAlert.configuration(
            for: makeRequest(candidates: [work], answer: answer))

        try #require(configuration.buttons.first).action()

        #expect(answer.answered.map { $0?.id } == [work.id])
    }

    @Test("Pass Through answers with whichever guest the popup is showing")
    func passThroughReadsTheChooser() throws {
        let answer = Answer()
        let work = makeInstance(named: "Work")
        let play = makeInstance(named: "Play")
        let configuration = USBAccessoryPairingAlert.configuration(
            for: makeRequest(candidates: [work, play], answer: answer))
        let popUp = try #require(chooser(in: configuration))

        // Read at click time, not at build time: the popup is what the user was
        // deciding with while the sheet was up.
        popUp.selectItem(at: 1)
        try #require(configuration.buttons.first).action()

        #expect(answer.answered.map { $0?.id } == [play.id])
    }
}
