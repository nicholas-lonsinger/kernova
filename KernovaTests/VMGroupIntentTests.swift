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
    private func makeGateway(over harness: WiredCommandCore) -> VMIntentGateway {
        VMIntentGateway(
            commands: harness.core, readiness: LibraryReadiness(awaitReady: {}),
            index: MockVMEntityIndex(), record: makeTestIndexRecord())
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
        let harness = WiredCommandCore()
        let alpha = harness.register(name: "Alpha")
        harness.register(name: "Beta", guestOS: .macOS)
        let folder = try harness.library.createFolder(named: "Lab")
        let smart = try harness.library.organization.createSmartGroup(
            named: "Linux", filter: VMLibraryFilter(guestOSes: [.linux]))

        let groups = try await makeGateway(over: harness).groups()

        #expect(groups.map(\.id) == [smart.id, folder.id])
        #expect(groups.map(\.kind) == [.smartGroup, .folder])
        #expect(groups[0].members.map(\.id) == [alpha.id])
        #expect(groups[0].members.map(\.name) == ["Alpha"])
        #expect(groups[1].members.isEmpty)
    }

    @Test("A typed group name matches as a typed VM name does: trimmed, ignoring case and diacritics")
    func groupNameMatchesAsAVMNameDoes() async throws {
        let harness = WiredCommandCore()
        let cafe = try harness.library.createFolder(named: "Café Lab")
        try harness.library.organization.createSmartGroup(named: "Other", filter: VMLibraryFilter())
        let gateway = makeGateway(over: harness)

        #expect(try await gateway.groups(matching: " cafe ").map(\.id) == [cafe.id])
        #expect(try await gateway.groups(matching: "CAFÉ").map(\.id) == [cafe.id])
    }

    // MARK: - Action

    @Test("The group action runs once on the group and answers the VMs it was done to")
    func groupActionAnswersTheDoneVMs() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization)
        let alpha = harness.register(name: "Alpha", phase: .running(sessionID: UUID()))
        let beta = harness.register(name: "Beta")
        let outside = harness.register(name: "Outside", phase: .running(sessionID: UUID()))
        let folder = try harness.library.createFolder(named: "Running", members: [alpha.id, beta.id])

        let done = try await makeGateway(over: harness).groupAction(
            .stop, on: VMGroupReference(.folder, named: folder.id.uuidString))

        // Beta is passed over, already stopped: the one shutdown request is
        // Alpha's, and the VM outside the group is never asked.
        #expect(done.map(\.id) == [alpha.id])
        #expect(virtualization.stopCallCount == 1)
        #expect(alpha.status == .stopped)
        #expect(beta.status == .stopped)
        #expect(outside.status == .running)
    }

    @Test("A VM the action was done to and that has since been deleted is left out of the answer, in group order")
    func groupActionLeavesOutAVMDeletedSince() async throws {
        let virtualization = SuspendingMockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization)
        // Library order differs from the folder's, so an answer re-listed in
        // library order rather than kept in group order is caught.
        let alpha = harness.register(name: "Alpha")
        let beta = harness.register(name: "Beta")
        let gone = harness.register(name: "Gone")
        try harness.library.createFolder(named: "Lab", members: [beta.id, gone.id, alpha.id])
        let gateway = makeGateway(over: harness)

        let action = Task {
            try await gateway.groupAction(.start, on: VMGroupReference(.folder, named: "Lab"))
        }
        // Beta's start, then Gone's, each let through in turn.
        await virtualization.waitUntilSuspended()
        virtualization.resumeSuspended()
        await virtualization.waitUntilSuspended()
        virtualization.resumeSuspended()
        // Alpha's start is under way, so Gone's turn is over: it was started.
        await virtualization.waitUntilSuspended()
        #expect(gone.status == .running)
        try await harness.core.stop(.id(gone.id), disposition: .force, consent: .all, timeout: nil)
        try await harness.core.delete(.id(gone.id), permanently: true, alsoRemoving: [], consent: .all)
        virtualization.shouldSuspendOnStart = false
        virtualization.resumeSuspended()

        let done = try await action.value

        #expect(done.map(\.id) == [beta.id, alpha.id])
        #expect(beta.status == .running && alpha.status == .running)
    }

    @Test("A VM the action left undone fails the intent, naming each such VM")
    func undoneFailsTheIntent() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization)
        let alpha = harness.register(name: "Alpha")
        let beta = harness.register(name: "Beta")
        virtualization.startErrors[alpha.id] = NSError(
            domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "No."])
        try harness.library.createFolder(named: "Lab", members: [alpha.id, beta.id])
        let gateway = makeGateway(over: harness)

        let failure = try await #require(throws: CommandError.self) {
            _ = try await gateway.groupAction(.start, on: VMGroupReference(.folder, named: "Lab"))
        }

        guard case .operationFailed(let verb, let title, let message, _) = failure else {
            Issue.record("expected the undone VM to fail the intent, got \(String(describing: failure))")
            return
        }
        #expect(verb == .start)
        #expect(title == "Couldn\u{2019}t Start Every VM in \u{201C}Lab\u{201D}")
        // One line, naming only the VM left undone, carrying its own failure.
        #expect(message.hasPrefix("Couldn\u{2019}t start Alpha: "))
        #expect(message.contains("No."))
        #expect(!message.contains("Beta"))
        #expect(alpha.status == .error)
        #expect(beta.status == .running)
    }
}
