import AppIntents
import Foundation
import KernovaKit
import KernovaTestSupport
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
