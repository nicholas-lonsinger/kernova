import AppIntents
import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// The library half of the App Intents surface: clone, rename, delete, and the
/// two cancels — what each dispatches, and how narrowly the delete is offered.
///
/// Driven through the gateway rather than through the intents, which resolve
/// their `@Dependency` only inside a live intent session.
@Suite("VM Library Intent Tests")
@MainActor
struct VMLibraryIntentTests {
    private func makeGateway(_ commands: MockVMCommanding) -> VMIntentGateway {
        VMIntentGateway(
            commands: commands, awaitReady: {}, refreshShortcutVocabulary: {},
            index: MockVMEntityIndex())
    }

    /// A library of one VM, which every verb here addresses.
    @discardableResult
    private func seed(_ commands: MockVMCommanding, vm: UUID) -> VMSummary {
        let summary = VMSummary(id: vm, name: "Wired", status: "stopped")
        commands.library = [summary]
        return summary
    }

    // MARK: - Machine Identity

    @Test("Every clone identity is offered, named, and maps back to itself")
    func cloneIdentitiesMirrorEveryMachineIdentity() {
        for identity in CloneMachineIdentity.allCases {
            let offered = VMCloneIdentity(identity)
            #expect(offered.identity == identity)
            #expect(VMCloneIdentity.caseDisplayRepresentations[offered] != nil)
        }
    }

    // MARK: - Verb Dispatch

    @Test("Every library verb addresses its VM by identifier, never by name")
    func verbsAddressByIdentifier() async throws {
        let commands = MockVMCommanding()
        let vm = UUID()
        seed(commands, vm: vm)
        let gateway = makeGateway(commands)

        _ = try await gateway.clone(vm, machineIdentity: .keep)
        try await gateway.rename(vm, to: "Renamed")
        try await gateway.delete(vm, confirmed: true)
        try await gateway.cancelPreparing(vm, confirmed: true)
        try await gateway.cancelGuestSetup(vm, confirmed: true)

        #expect(commands.cloneCalls.map(\.selector) == [.id(vm)])
        #expect(commands.cloneCalls.map(\.machineIdentity) == [.keep])
        #expect(commands.renameCalls.map(\.selector) == [.id(vm)])
        #expect(commands.renameCalls.map(\.newName) == ["Renamed"])
        #expect(commands.deleteCalls.map(\.selector) == [.id(vm)])
        #expect(commands.cancelPreparingCalls.map(\.selector) == [.id(vm)])
        #expect(commands.cancelGuestSetupCalls.map(\.selector) == [.id(vm)])
    }

    @Test("A clone answers the row the copy fills, read in full")
    func cloneAnswersTheNewRow() async throws {
        let commands = MockVMCommanding()
        let vm = UUID()
        seed(commands, vm: vm)
        commands.cloneResult = VMSummary(id: UUID(), name: "Wired 2", status: "preparing")

        let copy = try await makeGateway(commands).clone(vm, machineIdentity: .followPreference)

        #expect(copy.id == commands.cloneResult?.id)
        #expect(copy.name == "Wired 2")
        #expect(copy.status == "preparing")
    }

    // MARK: - Consent

    /// The narrowest delete the core offers: the bundle to the Trash, and
    /// nothing else. A permanent delete is a user-confirmed exception to the
    /// project's file-deletion rule, and external attachments are files this
    /// surface never showed anybody.
    @Test("A delete asks once, then trashes the bundle alone")
    func deleteConsentTrashesTheBundleAlone() async throws {
        let commands = MockVMCommanding()
        let vm = UUID()
        seed(commands, vm: vm)
        commands.deleteConsentPrompt = ConfirmationPrompt(
            kind: .deleteVM,
            title: "Move to the Trash?",
            message: "The bundle is moved to the Trash.",
            confirmTitle: "Move to Trash",
            dismissTitle: "Cancel")
        let gateway = makeGateway(commands)
        var asked: [ConfirmationPrompt] = []

        try await VMIntentConsent.run(prompting: { asked.append($0) }) { confirmed in
            try await gateway.delete(vm, confirmed: confirmed)
        }

        #expect(asked.map(\.kind) == [.deleteVM])
        #expect(commands.deleteCalls.map(\.confirmed) == [false, true])
        #expect(commands.deleteCalls.allSatisfy { !$0.permanently })
        #expect(commands.deleteCalls.allSatisfy { $0.alsoRemoving.isEmpty })
    }

    @Test("Both cancels ask once and re-issue with the consent")
    func cancelsRetryTheirVerb() async throws {
        let commands = MockVMCommanding()
        let vm = UUID()
        seed(commands, vm: vm)
        commands.cancelPreparingConsentPrompt = ConfirmationPrompt(
            kind: .cancelPreparing, title: "Cancel Copy?", message: "Partial files are removed.",
            confirmTitle: "Stop Copying", dismissTitle: "Continue")
        commands.cancelGuestSetupConsentPrompt = ConfirmationPrompt(
            kind: .cancelGuestSetup, title: "Cancel Download?", message: "Progress is saved.",
            confirmTitle: "Cancel Download", dismissTitle: "Keep Downloading")
        let gateway = makeGateway(commands)
        var asked: [ConfirmationPrompt] = []

        try await VMIntentConsent.run(prompting: { asked.append($0) }) { confirmed in
            try await gateway.cancelPreparing(vm, confirmed: confirmed)
        }
        try await VMIntentConsent.run(prompting: { asked.append($0) }) { confirmed in
            try await gateway.cancelGuestSetup(vm, confirmed: confirmed)
        }

        #expect(asked.map(\.kind) == [.cancelPreparing, .cancelGuestSetup])
        #expect(commands.cancelPreparingCalls.map(\.confirmed) == [false, true])
        #expect(commands.cancelGuestSetupCalls.map(\.confirmed) == [false, true])
    }

    // MARK: - Error Surfacing

    @Test("A refusal from the core reaches the caller unchanged")
    func refusalsPassThrough() async throws {
        let commands = MockVMCommanding()
        let vm = UUID()
        seed(commands, vm: vm)
        commands.cloneError = CommandError.invalidState(
            vm: commands.library[0], current: .running, allowed: [.stop])

        await #expect(throws: CommandError.self) {
            _ = try await makeGateway(commands).clone(vm, machineIdentity: .new)
        }
    }
}
