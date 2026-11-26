import AppKit
import Foundation
import KernovaCommandModel
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// What each of the prompt's buttons answers with.
@Suite("USB Accessory Pairing Alert Tests", .caseScoped)
@MainActor
struct USBAccessoryPairingAlertTests {
    private final class Answer {
        var answered: [VMInstance?] = []
    }

    private func makeRequest(candidates: [VMInstance], answer: Answer)
        -> USBAccessoryPairingRequest
    {
        USBAccessoryPairingRequest(
            id: UUID(),
            accessory: USBAccessorySummary(
                registryID: 7, name: "Samsung Type-C", vendorID: 0x04E8, productID: 0x6300,
                deviceID: nil, key: nil),
            candidates: candidates,
            answer: { answer.answered.append($0) })
    }

    @Test("Both shapes offer the same two buttons, and exactly one Return")
    func buttonsAreTheSameInBothShapes() {
        let answer = Answer()
        for count in 1...2 {
            let candidates = (0..<count).map { VMInstanceFixture.make(name: "VM \($0)") }
            let configuration = USBAccessoryPairingAlert.configuration(
                for: makeRequest(candidates: candidates, answer: answer))

            #expect(configuration.buttons.map(\.title) == ["Pass Through", "Keep on Mac"], "\(count)")
            // The trailing edge — the first listed — is the action, and Escape
            // leaves the accessory where it already is.
            #expect(configuration.buttons.filter { $0.role == .default }.count == 1, "\(count)")
            #expect(configuration.buttons.last?.role == .cancel, "\(count)")
        }
    }
}
