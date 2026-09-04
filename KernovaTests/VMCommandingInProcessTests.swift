import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// The four facade requirements no wire verb routes — the delete sheet's and
/// the snapshot pane's reads, and the start-failure recovery — reached through
/// `any VMCommanding` rather than a concrete implementation.
@Suite("VMCommanding In-Process Requirements Tests")
@MainActor
struct VMCommandingInProcessTests {
    /// A double behind the existential, so each read below is exercised as a
    /// protocol requirement rather than a method on the concrete core.
    private func makeFacade(vmNamed name: String = "Subject")
        -> (commands: any VMCommanding, mock: MockVMCommanding, vm: VMSummary)
    {
        let mock = MockVMCommanding()
        let vm = VMSummary(id: UUID(), name: name, status: "stopped")
        mock.library = [vm]
        return (mock, mock, vm)
    }

    @Test("snapshotOnDiskBytes addresses its VM by selector and answers per snapshot")
    func snapshotOnDiskBytesAnswersPerSnapshot() async throws {
        let (commands, mock, vm) = makeFacade()
        let snapshot = UUID()
        mock.snapshotBytes = [snapshot: 4096]

        let bytes = try await commands.snapshotOnDiskBytes(of: .id(vm.id))

        #expect(bytes == [snapshot: 4096])
        #expect(mock.snapshotOnDiskBytesSelectors == [.id(vm.id)])
    }

    @Test("externalAttachments addresses its VM by selector and answers the offered files")
    func externalAttachmentsAnswerTheOfferedFiles() async throws {
        let (commands, mock, vm) = makeFacade()
        mock.externalAttachmentsToReturn = [
            ExternalAttachment(
                reference: ExternalFileReference(
                    id: UUID(), kind: .storageDisk, label: "Scratch",
                    path: "/Volumes/External/data.img", bookmark: nil),
                sharedWithVMNames: ["Sibling"], isMissing: false)
        ]

        let attachments = try await commands.externalAttachments(of: .id(vm.id))

        #expect(attachments.map(\.label) == ["Scratch"])
        #expect(attachments.first?.isShared == true)
        #expect(mock.externalAttachmentsSelectors == [.id(vm.id)])
    }

    @Test("sharingVMNames carries the path and bookmark it was asked about")
    func sharingVMNamesCarriesThePathAndBookmark() async throws {
        let (commands, mock, vm) = makeFacade()
        mock.sharingVMNamesToReturn = ["Sibling"]
        let bookmark = Data([1, 2, 3])

        let names = try await commands.sharingVMNames(
            .id(vm.id), path: "/Volumes/External/data.img", bookmark: bookmark)

        #expect(names == ["Sibling"])
        let call = try #require(mock.sharingVMNamesCalls.first)
        #expect(call.selector == .id(vm.id))
        #expect(call.path == "/Volumes/External/data.img")
        #expect(call.bookmark == bookmark)
    }

    @Test("A read for a VM that left the library refuses with notFound")
    func aReadForADepartedVMRefuses() async throws {
        let (commands, _, _) = makeFacade()

        await #expect(throws: CommandError.self) {
            try await commands.externalAttachments(of: .id(UUID()))
        }
    }

    @Test("removeStartFailedAttachmentAndStart carries the attachment its selector names")
    func recoveryCarriesItsAttachment() async throws {
        let (commands, mock, vm) = makeFacade()
        let failure = StartFailedAttachment(
            kind: .removableMedia, id: UUID(), label: "Installer", message: "could not open")

        await commands.removeStartFailedAttachmentAndStart(.id(vm.id), attachment: failure)

        let call = try #require(mock.removeStartFailedAttachmentCalls.first)
        #expect(call.selector == .id(vm.id))
        #expect(call.attachment == failure)
    }
}
