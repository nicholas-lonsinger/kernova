import AppIntents
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Change Virtual Machine Setting: which settings Shortcuts offers, and what a
/// write dispatches and answers.
///
/// Driven through the gateway rather than through the intent, which resolves
/// its `@Dependency` only inside a live intent session.
@Suite("VM Setting Intent Tests", .caseScoped)
@MainActor
struct VMSettingIntentTests {
    private func makeGateway(over harness: WiredCommandCore) -> VMIntentGateway {
        VMIntentGateway(
            commands: harness.core, readiness: LibraryReadiness(awaitReady: {}),
            index: MockVMEntityIndex(), record: makeTestIndexRecord())
    }

    @Test("Turning clipboard passthrough on asks once, then re-issues the write with the consent")
    func clipboardPassthroughAsks() async throws {
        let harness = WiredCommandCore()
        let vm = harness.register(name: "Wired", guestOS: .macOS) { $0.clipboardSharingEnabled = true }
        let gateway = makeGateway(over: harness)
        var asked: [ConfirmationPrompt] = []

        try await VMConsentPolicy.run(prompting: { asked.append($0) }) { consent in
            _ = try await gateway.setConfiguration(
                vm.id, key: "clipboard.passthrough", value: "true", consent: consent)
        }

        #expect(asked == [ClipboardPassthroughConsent.prompt(vmName: "Wired")])
        #expect(vm.configuration.clipboardPassthroughEnabled)
    }
}
