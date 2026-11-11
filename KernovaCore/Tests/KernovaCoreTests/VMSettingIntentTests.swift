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

    @Test("Resolving by name, or by a typed fragment, answers only the settings asked for, in registry order")
    func lookupFilters() async throws {
        let gateway = makeGateway(over: WiredCommandCore())

        #expect(
            await gateway.configurationKeys(named: ["network.mac", "nonsense", "cpus"]).map(\.id)
                == ["cpus", "network.mac"])
        #expect(
            await gateway.configurationKeys(matching: "NETWORK.M").map(\.id)
                == ["network.mode", "network.membership", "network.mac"])
    }

    @Test("A write assigns the value to the key, addressing the VM by identifier")
    func aWriteAssignsByKey() async throws {
        let harness = WiredCommandCore()
        // Name twins: a write addressed by name would be refused as ambiguous.
        let vm = harness.register(name: "Wired")
        let twin = harness.register(name: "Wired")

        let held = try await makeGateway(over: harness).setConfiguration(
            vm.id, key: "network.membership", value: "isolated", consent: .none)

        #expect(held == "isolated")
        #expect(vm.configuration.networkMembership == .isolated)
        #expect(twin.configuration.networkMembership == .common)
    }

    @Test("Turning clipboard passthrough on asks once, then re-issues the write with the consent")
    func clipboardPassthroughAsks() async throws {
        let harness = WiredCommandCore()
        let vm = harness.register(name: "Wired") { $0.clipboardSharingEnabled = true }
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
