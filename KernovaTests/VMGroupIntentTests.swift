import AppIntents
import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// The group half of the App Intents surface: how Shortcuts names a smart
/// group or folder, and what the group action intent dispatches and reports.
///
/// Driven through the gateway rather than through the intents, which resolve
/// their `@Dependency` only inside a live intent session.
@Suite("VM Group Intent Tests", .caseScoped)
@MainActor
struct VMGroupIntentTests {
    private func makeGateway(_ commands: MockVMCommanding) -> VMIntentGateway {
        VMIntentGateway(
            commands: commands, readiness: LibraryReadiness(awaitReady: {}),
            index: MockVMEntityIndex(), record: makeTestIndexRecord())
    }

    private func makeSummary(name: String) -> VMSummary {
        VMSummary(id: UUID(), name: name, status: "stopped", ipAddress: .unavailable, heldByAnotherCopy: false)
    }

    // MARK: - Entity

    @Test("Every group kind and every group action is offered, named, and maps back to itself")
    func choicesMirrorTheirKitTypes() {
        for kind in VMGroupKind.allCases {
            #expect(VMGroupKindChoice(kind).kind == kind)
            #expect(VMGroupKindChoice.caseDisplayRepresentations[VMGroupKindChoice(kind)] != nil)
        }
        for action in VMGroupAction.allCases {
            #expect(VMGroupActionChoice(action).action == action)
            #expect(VMGroupActionChoice.caseDisplayRepresentations[VMGroupActionChoice(action)] != nil)
        }
    }

    @Test("A group entity carries its summary, reads its kind in words, and names itself to a command")
    func entityDescribesItsSummary() throws {
        let group = GroupSummary(id: UUID(), name: "Lab", kind: .folder, members: [])

        let entity = VMGroupEntity(group, members: [])

        #expect(entity.id == group.id)
        #expect(entity.name == "Lab")
        #expect(entity.kind == .folder)
        #expect(entity.reference == VMGroupReference(.folder, named: group.id.uuidString))
        #expect(String(localized: entity.displayRepresentation.title) == "Lab")
        #expect(String(localized: try #require(entity.displayRepresentation.subtitle)) == "Folder")
    }

    @Test("The groups list in the core's order, each VM in one read in full")
    func groupsReadTheirMembersInFull() async throws {
        let commands = MockVMCommanding()
        let alpha = makeSummary(name: "Alpha")
        commands.library = [alpha, makeSummary(name: "Beta")]
        let smart = GroupSummary(id: UUID(), name: "Linux", kind: .smartGroup, members: [alpha])
        let folder = GroupSummary(id: UUID(), name: "Lab", kind: .folder, members: [])
        commands.groupsToReturn = [smart, folder]

        let groups = try await makeGateway(commands).groups()

        #expect(groups.map(\.id) == [smart.id, folder.id])
        #expect(groups.map(\.kind) == [.smartGroup, .folder])
        #expect(groups[0].members.map(\.name) == ["Alpha"])
    }

    @Test("A typed group name matches as a typed VM name does: trimmed, ignoring case and diacritics")
    func groupNameMatchesAsAVMNameDoes() async throws {
        let commands = MockVMCommanding()
        let cafe = GroupSummary(id: UUID(), name: "Café Lab", kind: .folder, members: [])
        let other = GroupSummary(id: UUID(), name: "Other", kind: .smartGroup, members: [])
        commands.groupsToReturn = [cafe, other]
        let gateway = makeGateway(commands)

        #expect(try await gateway.groups(matching: " cafe ").map(\.id) == [cafe.id])
        #expect(try await gateway.groups(matching: "CAFÉ").map(\.id) == [cafe.id])
    }

    // MARK: - Action

    @Test("The group action runs once on the group and answers the VMs it was done to")
    func groupActionAnswersTheDoneVMs() async throws {
        let commands = MockVMCommanding()
        let alpha = makeSummary(name: "Alpha")
        let beta = makeSummary(name: "Beta")
        commands.library = [alpha, beta]
        let group = VMGroupReference(.smartGroup, named: UUID().uuidString)
        commands.groupActionReport = VMGroupActionReport(
            action: .stop, groupKind: .smartGroup, groupID: UUID(), groupName: "Running",
            results: [
                VMGroupActionResult(vm: alpha, outcome: .done(verb: .stop)),
                VMGroupActionResult(vm: beta, outcome: .passedOver(reason: .state)),
            ])

        let done = try await makeGateway(commands).groupAction(.stop, on: group)

        #expect(done.map(\.id) == [alpha.id])
        #expect(commands.groupActionCalls.map(\.action) == [.stop])
        #expect(commands.groupActionCalls.map(\.group) == [group])
    }

    @Test("A VM the action was done to and that has since been deleted is left out of the answer, in group order")
    func groupActionLeavesOutAVMDeletedSince() async throws {
        let commands = MockVMCommanding()
        let alpha = makeSummary(name: "Alpha")
        let gone = makeSummary(name: "Gone")
        let beta = makeSummary(name: "Beta")
        commands.library = [alpha, beta]
        commands.groupActionReport = VMGroupActionReport(
            action: .start, groupKind: .folder, groupID: UUID(), groupName: "Lab",
            results: [
                VMGroupActionResult(vm: beta, outcome: .done(verb: .start)),
                VMGroupActionResult(vm: gone, outcome: .done(verb: .start)),
                VMGroupActionResult(vm: alpha, outcome: .done(verb: .start)),
            ])

        let index = MockVMEntityIndex()
        let gateway = VMIntentGateway(
            commands: commands, readiness: LibraryReadiness(awaitReady: {}), index: index,
            record: makeTestIndexRecord())

        let done = try await gateway.groupAction(.start, on: VMGroupReference(.folder, named: "Lab"))

        #expect(done.map(\.id) == [beta.id, alpha.id])
        // Read VM by VM: the one listing is the readiness sync's.
        try await index.awaitOperations(1)
        #expect(commands.listCallCount == 1)
    }

    @Test("A VM the action left undone fails the intent, naming each such VM")
    func undoneFailsTheIntent() async throws {
        let commands = MockVMCommanding()
        let alpha = makeSummary(name: "Alpha")
        commands.library = [alpha]
        let report = VMGroupActionReport(
            action: .start, groupKind: .folder, groupID: UUID(), groupName: "Lab",
            results: [
                VMGroupActionResult(
                    vm: alpha,
                    outcome: .failed(error: .operationFailed(verb: .start, title: nil, message: "No.", recovery: nil)))
            ])
        commands.groupActionReport = report

        await #expect(
            throws: CommandError.operationFailed(
                verb: .start, title: "Couldn\u{2019}t Start Every VM in \u{201C}Lab\u{201D}",
                message: "Couldn\u{2019}t start Alpha: No.")
        ) {
            try await makeGateway(commands).groupAction(.start, on: VMGroupReference(.folder, named: "Lab"))
        }
    }
}
