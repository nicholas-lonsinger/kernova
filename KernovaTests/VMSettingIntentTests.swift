import AppIntents
import Foundation
import KernovaKit
import Testing

@testable import Kernova

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

    @Test("The settings offered are the registry's keys, in its order, each described by its summary")
    func settingsAreTheRegistryKeys() async throws {
        let settings = await makeGateway(over: WiredCommandCore()).configurationKeys()

        #expect(settings.map(\.id) == VMConfigurationKeyRegistry.keys.map(\.name))
        let mac = try #require(settings.first { $0.id == VMConfigurationKeyRegistry.networkMAC.name })
        #expect(String(localized: mac.displayRepresentation.title) == "network.mac")
        let subtitle = try #require(mac.displayRepresentation.subtitle)
        #expect(String(localized: subtitle) == VMConfigurationKeyRegistry.networkMAC.summary)
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

    @Test("A write answers the value the key ended up holding, not the one written")
    func aWriteAnswersTheHeldValue() async throws {
        let harness = WiredCommandCore()
        let vm = harness.register(name: "Wired")

        let held = try await makeGateway(over: harness).setConfiguration(
            vm.id, key: "network.mac", value: VMConfigurationKeyRegistry.newMACAddressValue, consent: .none)

        #expect(held != VMConfigurationKeyRegistry.newMACAddressValue)
        #expect(held == vm.configuration.macAddress)
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

    @Test("A refusal from the core reaches the caller unchanged")
    func refusalsPassThrough() async throws {
        let harness = WiredCommandCore()
        let vm = harness.register(name: "Wired")

        await #expect(
            throws: CommandError.invalidArgument(
                "network.membership takes common, isolated, or a network\u{2019}s name or identifier, "
                    + "not \u{201C}Nowhere\u{201D}.")
        ) {
            _ = try await makeGateway(over: harness).setConfiguration(
                vm.id, key: "network.membership", value: "Nowhere", consent: .none)
        }
        #expect(vm.configuration.networkMembership == .common)
    }
}
