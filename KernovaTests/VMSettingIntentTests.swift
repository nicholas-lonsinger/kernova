import AppIntents
import Foundation
import KernovaKit
import KernovaTestSupport
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
    private func makeGateway(_ commands: MockVMCommanding) -> VMIntentGateway {
        VMIntentGateway(
            commands: commands, readiness: LibraryReadiness(awaitReady: {}),
            index: MockVMEntityIndex(), record: makeTestIndexRecord())
    }

    /// A library of one VM, which every write here addresses.
    private func seed(_ commands: MockVMCommanding) -> UUID {
        let id = UUID()
        commands.library = [
            VMSummary(id: id, name: "Wired", status: "stopped", ipAddress: .unavailable, heldByAnotherCopy: false)
        ]
        return id
    }

    @Test("The settings offered are the registry's keys, in its order, each described by its summary")
    func settingsAreTheRegistryKeys() async throws {
        let commands = MockVMCommanding()
        commands.configurationKeyDescriptors = VMConfigurationKeyRegistry.keys.map(\.descriptor)

        let settings = await makeGateway(commands).configurationKeys()

        #expect(settings.map(\.id) == VMConfigurationKeyRegistry.keys.map(\.name))
        let mac = try #require(settings.first { $0.id == VMConfigurationKeyRegistry.networkMAC.name })
        #expect(String(localized: mac.displayRepresentation.title) == "network.mac")
        let subtitle = try #require(mac.displayRepresentation.subtitle)
        #expect(String(localized: subtitle) == VMConfigurationKeyRegistry.networkMAC.summary)
    }

    @Test("Resolving by name, or by a typed fragment, answers only the settings asked for, in registry order")
    func lookupFilters() async throws {
        let commands = MockVMCommanding()
        commands.configurationKeyDescriptors = VMConfigurationKeyRegistry.keys.map(\.descriptor)
        let gateway = makeGateway(commands)

        #expect(
            await gateway.configurationKeys(named: ["network.mac", "nonsense", "cpus"]).map(\.id)
                == ["cpus", "network.mac"])
        #expect(
            await gateway.configurationKeys(matching: "NETWORK.M").map(\.id)
                == ["network.mode", "network.membership", "network.mac"])
    }

    @Test("A write assigns the value to the key, addressing the VM by identifier")
    func aWriteAssignsByKey() async throws {
        let commands = MockVMCommanding()
        let vm = seed(commands)

        _ = try await makeGateway(commands).setConfiguration(
            vm, key: "network.membership", value: "isolated", consent: .none)

        #expect(commands.setConfigurationCalls.map(\.selector) == [.id(vm)])
        #expect(
            commands.setConfigurationCalls.map(\.assignments)
                == [[ConfigurationEntry(key: "network.membership", value: "isolated")]])
    }

    @Test("A write answers the value the key ended up holding, not the one written")
    func aWriteAnswersTheHeldValue() async throws {
        let commands = MockVMCommanding()
        let vm = seed(commands)
        commands.setConfigurationAnswer = [ConfigurationEntry(key: "network.mac", value: "02:11:22:33:44:55")]

        let held = try await makeGateway(commands).setConfiguration(
            vm, key: "network.mac", value: "new", consent: .none)

        #expect(held == "02:11:22:33:44:55")
    }

    @Test("Turning clipboard passthrough on asks once, then re-issues the write with the consent")
    func clipboardPassthroughAsks() async throws {
        let commands = MockVMCommanding()
        let vm = seed(commands)
        commands.setConfigurationConsentPrompt = ClipboardPassthroughConsent.prompt(vmName: "Wired")
        let gateway = makeGateway(commands)
        var asked: [ConfirmationPrompt] = []

        try await VMConsentPolicy.run(prompting: { asked.append($0) }) { consent in
            _ = try await gateway.setConfiguration(
                vm, key: "clipboard.passthrough", value: "true", consent: consent)
        }

        #expect(asked.map(\.kind) == [.enableClipboardPassthrough])
        #expect(
            commands.setConfigurationCalls.map { $0.consent.covers(.enableClipboardPassthrough) }
                == [false, true])
    }

    @Test("A refusal from the core reaches the caller unchanged")
    func refusalsPassThrough() async throws {
        let commands = MockVMCommanding()
        let vm = seed(commands)
        let refusal = CommandError.invalidArgument("network.membership takes common, isolated, or a network.")
        commands.setConfigurationError = refusal

        await #expect(throws: refusal) {
            _ = try await makeGateway(commands).setConfiguration(
                vm, key: "network.membership", value: "Nowhere", consent: .none)
        }
    }
}
