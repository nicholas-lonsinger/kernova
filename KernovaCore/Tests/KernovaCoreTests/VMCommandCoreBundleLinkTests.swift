import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// A bring-up of a VM whose bundle holds a symbolic link, driven through the
/// command core as every door drives it.
@Suite("VMCommandCore Bundle Link Tests", .serialized, .caseScoped)
@MainActor
struct VMCommandCoreBundleLinkTests {
    private let preferences = makeTestPreferences()

    private static let linkedDisk =
        "\u{201C}Disk.asif\u{201D} is a symbolic link, and Kernova supports only real files and folders inside a virtual machine."

    @Test("A start of a VM whose disk is a symbolic link is refused, naming the link, and boots nothing")
    func startRefusesALinkedDisk() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let instance = harness.register(name: "Linked")
        try VMInstanceFixture.linkDiskImage(of: instance)

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        }

        #expect(
            error
                == .operationFailed(
                    verb: .start, title: "Couldn\u{2019}t Start \u{201C}Linked\u{201D}", message: Self.linkedDisk))
        #expect(virtualization.startCallCount == 0)
        #expect(instance.status == .stopped)
    }

    @Test("A resume of a saved state in a bundle holding a symbolic link is refused, keeping the saved state")
    func resumeRefusesALinkedDiskKeepingTheSavedState() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let instance = harness.register(name: "Linked")
        try VMInstanceFixture.writeSaveFile(for: instance)
        instance.activity.placeForTesting(.suspended)
        try VMInstanceFixture.linkDiskImage(of: instance)

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.resume(.id(instance.id), consent: .none)
        }

        #expect(
            error
                == .operationFailed(
                    verb: .resume, title: "Couldn\u{2019}t Resume \u{201C}Linked\u{201D}", message: Self.linkedDisk))
        #expect(virtualization.startCallCount == 0)
        #expect(instance.status == .suspended)
        #expect(FileManager.default.fileExists(atPath: instance.bundleLayout.saveFileURL.path(percentEncoded: false)))
    }
}
