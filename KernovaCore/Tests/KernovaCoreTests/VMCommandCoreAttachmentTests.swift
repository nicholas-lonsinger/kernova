import Foundation
import KernovaAgentHost
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The attachment verbs, driven with no view model and no presenter: the
/// consent a trashing removal asks for, the files that are never trashed
/// however the removal is asked for, and the images and shares a running guest
/// may not be handed.
@Suite("VMCommandCore Attachment Tests", .serialized, .caseScoped)
@MainActor
struct VMCommandCoreAttachmentTests {
    private let preferences = makeTestPreferences()
    private let scratch = TestScratchDirectory(prefix: "VMCommandCoreAttachmentTests")

    private typealias Harness = WiredCommandCore.Scripted<MockVirtualizationService>

    private func makeHarness(
        diskImages: MockDiskImageService = MockDiskImageService(),
        usbAccessoryPassthrough: USBAccessoryPassthrough = .unavailable(.needsEntitlement),
        bundleProducts: AppBundleProducts = .testing
    ) -> Harness {
        Harness(
            WiredCommandCore(
                virtualization: MockVirtualizationService(), diskImages: diskImages,
                usbAccessoryPassthrough: usbAccessoryPassthrough, preferences: preferences,
                bundleProducts: bundleProducts))
    }

    @discardableResult
    private func makeInstance(
        in harness: Harness, name: String = "Core VM", phase: VMLifecyclePhase = .stopped,
        guestOS: VMGuestOS = .linux, mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: phase, guestOS: guestOS, library: harness.library,
            preferences: preferences, mutate: mutate)
    }

    private func externalPath(_ suffix: String) -> String {
        scratch.url
            .appendingPathComponent("\(UUID().uuidString)-\(suffix)")
            .path(percentEncoded: false)
    }

    // MARK: - Storage: removal

    @Test("A removal that keeps the file drops the entry and touches nothing on disk")
    func removeStorageDiskKeepingTheFile() async throws {
        let harness = makeHarness()
        let main = StorageDisk(path: "Disk.asif", label: "Main Disk", isInternal: true)
        let extra = StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        let instance = makeInstance(in: harness) { $0.storageDisks = [main, extra] }

        try await harness.core.removeStorageDisk(
            .id(instance.id), disk: extra.id, trashFile: false, consent: .none)

        #expect(instance.configuration.storageDisks?.map(\.id) == [main.id])
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test("A trashing removal asks for consent, then trashes the external file")
    func removeStorageDiskTrashesAfterConsent() async throws {
        let harness = makeHarness()
        let path = externalPath("external.img")
        let external = StorageDisk(path: path, label: "External", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeInstance(in: harness) { $0.storageDisks = [external, keeper] }

        let refusal = try await #require(throws: CommandError.self) {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: external.id, trashFile: true, consent: .none)
        }
        #expect(refusal.confirmationPrompt?.kind == .removeAttachment)
        #expect(refusal.confirmationPrompt?.confirmTitle == "Move to Trash")
        // Refused, so nothing moved.
        #expect(instance.configuration.storageDisks?.count == 2)

        try await harness.core.removeStorageDisk(
            .id(instance.id), disk: external.id, trashFile: true, consent: .all)

        #expect(instance.configuration.storageDisks?.map(\.id) == [keeper.id])
        #expect(harness.fileSystem.trashedURLs == [URL(fileURLWithPath: path)])
    }

    @Test("A file another VM still references is kept, however the removal is asked for")
    func removeStorageDiskKeepsASharedFile() async throws {
        let harness = makeHarness()
        let path = externalPath("shared.img")
        let disk = StorageDisk(path: path, label: "Shared", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let target = makeInstance(in: harness, name: "Target") { $0.storageDisks = [disk, keeper] }
        _ = makeInstance(in: harness, name: "Other") {
            $0.storageDisks = [StorageDisk(path: path, label: "Shared")]
        }

        // A shared file is offered detach-only, so that is what confirming does.
        let refusal = try await #require(throws: CommandError.self) {
            try await harness.core.removeStorageDisk(
                .id(target.id), disk: disk.id, trashFile: true, consent: .none)
        }
        #expect(refusal.confirmationPrompt?.confirmTitle == "Remove from VM")
        #expect(refusal.confirmationPrompt?.message.contains("Other") == true)

        try await harness.core.removeStorageDisk(
            .id(target.id), disk: disk.id, trashFile: true, consent: .all)

        #expect(target.configuration.storageDisks?.map(\.id) == [keeper.id])
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test(
        "A missing file answers success, and any other trash failure answers the file that stayed",
        arguments: [true, false])
    func removeStorageDiskTrashFailures(isInternal: Bool) async throws {
        let harness = makeHarness()
        let disk = { (name: String) in
            isInternal
                ? StorageDisk(path: "AdditionalDisks/\(name)", label: name, isInternal: true)
                : StorageDisk(path: self.externalPath(name), label: name, isInternal: false)
        }
        let ghost = disk("ghost.img")
        let locked = disk("locked.img")
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeInstance(in: harness) { $0.storageDisks = [ghost, locked, keeper] }

        harness.fileSystem.setTrashError(CocoaError(.fileNoSuchFile))
        try await harness.core.removeStorageDisk(
            .id(instance.id), disk: ghost.id, trashFile: true, consent: .all)

        harness.fileSystem.setTrashError(CocoaError(.fileWriteNoPermission))
        let failure = try await #require(throws: CommandError.self) {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: locked.id, trashFile: true, consent: .all)
        }

        // The entry goes either way; the caller is told which file stayed.
        #expect(instance.configuration.storageDisks?.map(\.id) == [keeper.id])
        let path =
            isInternal
            ? instance.bundleURL.appendingPathComponent(locked.path).path(percentEncoded: false)
            : locked.path
        guard case .filesKept(let kept) = failure else {
            Issue.record("expected the files-kept outcome, got \(failure)")
            return
        }
        #expect(kept.removal == .attachment(label: "locked.img", vm: instance.name))
        #expect(kept.files.map(\.path) == [path])
        // Told to the caller alone, never again as an unattended failure.
        #expect(harness.failures.isEmpty)
    }

    @Test("A disk detached while sharing resolves is refused, and its file is left alone")
    func removeStorageDiskRefusesADetachDuringTheResolve() async throws {
        let harness = makeHarness()
        let path = externalPath("external.img")
        let disk = StorageDisk(path: path, label: "External", isInternal: false)
        let other = StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        let instance = makeInstance(in: harness) { $0.storageDisks = [disk, other] }
        // A second surface removing the same row while this one's resolve is in
        // flight: the id this call decided to trash is no longer attached.
        harness.core.afterSharingResolveForTesting = {
            harness.library.editConfiguration(of: instance, as: .machineKeys) { $0.storageDisks = [other] }
        }

        let refusal = try await #require(throws: CommandError.self) {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: disk.id, trashFile: true, consent: .all)
        }

        #expect(refusal.isOperationFailure)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    // MARK: - Removable media

    /// Two running VMs, "A" listing `item` and "B" listing `bItems`.
    private func makeRunningPair(
        in harness: Harness, a item: RemovableMediaItem, b bItems: [RemovableMediaItem] = []
    ) -> (a: VMInstance, b: VMInstance) {
        let a = makeInstance(in: harness, name: "A", phase: .running(sessionID: UUID())) {
            $0.removableMedia = [item]
        }
        a.beginSessionContextForTesting()
        let b = makeInstance(in: harness, name: "B", phase: .running(sessionID: UUID())) {
            $0.removableMedia = bItems.isEmpty ? nil : bItems
        }
        b.beginSessionContextForTesting()
        return (a, b)
    }

    @Test("Attaching an image another running VM has open writable is refused before the commit")
    func attachRefusesAnImageAnotherVMWrites() throws {
        let harness = makeHarness()
        let path = externalPath("w.img")
        let (a, b) = makeRunningPair(in: harness, a: RemovableMediaItem(path: path, readOnly: false, label: "W"))

        let refusal = try #require(throws: CommandError.self) {
            try harness.core.attachRemovableMedia(.id(b.id), paths: [PickedFile(path: path, bookmark: nil)])
        }

        guard case .conflict(let vm, let other, .diskImage(_, writableThere: true)) = refusal
        else {
            Issue.record("refused with \(refusal)")
            return
        }
        #expect(vm.id == b.id)
        #expect(other.id == a.id)
        #expect(b.configuration.removableMedia == nil)
        #expect(harness.removableMedia.attachCallCount == 0)
    }

    @Test("Making writable an image another running VM has read-only is refused, and it stays read-only")
    func readWriteRefusesAnImageAnotherVMHas() throws {
        let harness = makeHarness()
        let path = externalPath("r.img")
        let mine = RemovableMediaItem(path: path, readOnly: true, label: "Mine")
        let (a, b) = makeRunningPair(
            in: harness, a: RemovableMediaItem(path: path, readOnly: true, label: "R"), b: [mine])

        let refusal = try #require(throws: CommandError.self) {
            try harness.core.setRemovableMediaReadOnly(.id(b.id), item: mine.id, readOnly: false)
        }

        guard
            case .conflict(_, let other, .diskImage("Mine", writableThere: false)) = refusal
        else {
            Issue.record("refused with \(refusal)")
            return
        }
        #expect(other.id == a.id)
        #expect(b.configuration.removableMedia?.first?.readOnly == true)
        #expect(harness.removableMedia.attachCallCount == 0)
    }

    @Test("A revert that would resume with an image another running VM writes is refused, naming it")
    func revertRefusesTheSnapshotsImageAnotherVMWrites() async throws {
        let harness = makeHarness()
        let path = externalPath("x.img")
        // B had X read-only when it took S; X has since moved to A, writable.
        let (a, b) = makeRunningPair(in: harness, a: RemovableMediaItem(path: path, readOnly: false, label: "X"))
        let atCapture = RemovableMediaItem(path: path, readOnly: true, label: "X")
        let snapshot = VMSnapshot(
            name: "S", kind: .warm, macAddress: nil,
            diskImages: VMCapturedDiskImages(storageDisks: nil, removableMedia: [atCapture]))
        b.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))
        var captured = b.configuration
        captured.removableMedia = [atCapture]
        harness.machineFiles.setCapturedConfiguration(captured, for: snapshot.id)

        let refusal = try await #require(throws: CommandError.self) {
            try await harness.core.revertToSnapshot(.id(b.id), snapshot: snapshot.id, consent: .all)
        }

        guard case .conflict(let vm, let other, .diskImage("X", writableThere: true)) = refusal else {
            Issue.record("refused with \(refusal)")
            return
        }
        #expect(vm.id == b.id)
        #expect(other.id == a.id)
        #expect(harness.virtualization.revertedSnapshots.isEmpty)
        #expect(b.configuration.removableMedia == nil)
    }

    @Test("A failed removable-disk write trashes only what the write may have left")
    func createRemovableMediaCleansUpOnlyAfterAWrite() async throws {
        for (error, expectsCleanup) in [
            (DiskImageError.writeFailed(NSError(domain: "t", code: 1)), true),
            (DiskImageError.templateMissing(sizeInGB: 16), false),
        ] {
            let diskImages = MockDiskImageService()
            diskImages.createDiskImageError = error
            let harness = makeHarness(diskImages: diskImages)
            let instance = makeInstance(in: harness)
            let destination = scratch.url
                .appendingPathComponent("\(UUID().uuidString).asif")

            let refusal = try await #require(throws: CommandError.self) {
                try await harness.core.createRemovableMedia(
                    .id(instance.id), sizeInGB: 16, destinationURL: destination)
            }

            #expect(refusal.isOperationFailure)
            #expect(instance.configuration.removableMedia == nil)
            #expect(harness.fileSystem.trashedURLs.isEmpty != expectsCleanup, "\(error)")
        }
    }

    @Test("Ejecting drops the entry and keeps the file")
    func ejectRemovableMedia() throws {
        let harness = makeHarness()
        let item = RemovableMediaItem(path: externalPath("media.iso"), readOnly: true)
        let instance = makeInstance(in: harness) { $0.removableMedia = [item] }

        try harness.core.ejectRemovableMedia(.id(instance.id), item: item.id)

        #expect(instance.configuration.removableMedia == nil)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test("A trashing removal of removable media asks for consent, then trashes the file")
    func removeRemovableMediaTrashesAfterConsent() async throws {
        let harness = makeHarness()
        let path = externalPath("media.iso")
        let item = RemovableMediaItem(path: path, readOnly: true)
        let instance = makeInstance(in: harness) { $0.removableMedia = [item] }

        let refusal = try await #require(throws: CommandError.self) {
            try await harness.core.removeRemovableMedia(
                .id(instance.id), item: item.id, trashFile: true, consent: .none)
        }
        #expect(refusal.confirmationPrompt?.kind == .removeAttachment)

        try await harness.core.removeRemovableMedia(
            .id(instance.id), item: item.id, trashFile: true, consent: .all)

        #expect(instance.configuration.removableMedia == nil)
        #expect(harness.fileSystem.trashedURLs == [URL(fileURLWithPath: path)])
    }

    @Test("The bundled Guest Agent installer is detached but never trashed")
    func removeGuestAgentInstallerKeepsTheFile() async throws {
        let agentPath = try #require(BundledGuestAgents.testing.macOSInstallerDiskImageURL)
            .path(percentEncoded: false)
        let harness = makeHarness()
        let item = RemovableMediaItem(
            path: agentPath, readOnly: true, label: BundledGuestAgents.macOSDiskLabel)
        let instance = makeInstance(in: harness) { $0.removableMedia = [item] }

        let refusal = try await #require(throws: CommandError.self) {
            try await harness.core.removeRemovableMedia(
                .id(instance.id), item: item.id, trashFile: true, consent: .none)
        }
        #expect(refusal.confirmationPrompt?.message.contains("isn't deleted") == true)

        try await harness.core.removeRemovableMedia(
            .id(instance.id), item: item.id, trashFile: true, consent: .all)

        #expect(instance.configuration.removableMedia == nil)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    // MARK: - Shared directories: a running macOS guest

    /// A folder that exists, so a live swap's validation finds it.
    private func folder(_ suffix: String) throws -> String {
        let path = externalPath(suffix)
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// A running macOS guest booted with `directories`, its session holding
    /// the share its boot built — or, with `serving`, the share given.
    private func makeRunningMacOSGuest(
        in harness: Harness, name: String = "Core VM", sharing directories: [SharedDirectory],
        serving: MacOSDirectoryShare? = nil
    ) throws -> VMInstance {
        let instance = makeInstance(
            in: harness, name: name, phase: .running(sessionID: UUID()), guestOS: .macOS
        ) { $0.sharedDirectories = directories.isEmpty ? nil : directories }
        let context = instance.beginSessionContextForTesting()
        if !directories.isEmpty {
            context.directoryShare =
                try serving ?? MacOSDirectoryShare.make(for: directories)
        }
        return instance
    }

    @Test("Removing one of two shares from a running macOS guest swaps live and lets the removed one go")
    func runningMacOSGuestRemovesAShareLive() throws {
        let harness = makeHarness()
        let kept = SharedDirectory(path: try folder("kept"))
        let going = SharedDirectory(path: try folder("going"))
        let instance = try makeRunningMacOSGuest(in: harness, sharing: [kept, going])

        try harness.core.removeSharedDirectory(.id(instance.id), directory: going.id)
        try harness.core.setSharedDirectoryReadOnly(
            .id(instance.id), directory: kept.id, readOnly: true)

        #expect(instance.configuration.sharedDirectories?.map(\.id) == [kept.id])
        #expect(instance.configuration.sharedDirectories?.first?.readOnly == true)
        #expect(instance.sessionContext?.directoryShare?.entries.map(\.id) == [kept.id])
        #expect(instance.sessionContext?.directoryShare?.entries.map(\.readOnly) == [true])
    }

    /// The device serves the folder it was built with; a later swap neither
    /// fails on the path the folder left nor re-points the mount at whatever
    /// folder now sits there.
    @Test("A live swap keeps serving a share whose folder moved from its stored path")
    func liveSwapKeepsWhatTheDeviceServes() throws {
        let harness = makeHarness()
        let served = try folder("served")
        for storedPathExists in [false, true] {
            let stored = externalPath("stored")
            if storedPathExists {
                try FileManager.default.createDirectory(
                    atPath: stored, withIntermediateDirectories: true)
            }
            let moved = SharedDirectory(path: stored, mountName: "moved")
            let serving = MacOSDirectoryShare(entries: [
                .init(id: moved.id, name: "moved", url: URL(fileURLWithPath: served), readOnly: false)
            ])
            let instance = try makeRunningMacOSGuest(
                in: harness, name: "Moved \(storedPathExists)", sharing: [moved], serving: serving)

            try harness.core.addSharedDirectories(
                .id(instance.id), paths: [PickedFile(path: try folder("added"), bookmark: nil)])

            let first = try #require(instance.sessionContext?.directoryShare?.entries.first)
            #expect(first == serving.entries[0], "stored path exists: \(storedPathExists)")
        }
    }

    @Test("A running macOS guest's first share and last share are refused by the rule that holds them")
    func runningMacOSGuestRefusesTheFirstAndLastShare() async throws {
        let harness = makeHarness()
        let empty = makeInstance(
            in: harness, name: "Empty", phase: .running(sessionID: UUID()), guestOS: .macOS)
        let only = SharedDirectory(path: try folder("only"))
        let single = makeInstance(
            in: harness, name: "Single", phase: .running(sessionID: UUID()), guestOS: .macOS
        ) { $0.sharedDirectories = [only] }

        for refusal in [
            try #require(throws: CommandError.self) {
                try harness.core.addSharedDirectories(
                    .id(empty.id), paths: [PickedFile(path: try folder("first"), bookmark: nil)])
            },
            try #require(throws: CommandError.self) {
                try harness.core.removeSharedDirectory(.id(single.id), directory: only.id)
            },
        ] {
            guard case .changeTakesStoppedVM(_, let current, let change) = refusal
            else {
                Issue.record("expected the stopped-VM rule, got \(refusal)")
                continue
            }
            #expect(current == .running)
            #expect(change == .firstOrLastSharedDirectory)
        }
        #expect(empty.configuration.sharedDirectories == nil)
        #expect(single.configuration.sharedDirectories == [only])
    }

    // MARK: - State gates

    @Test("A medium ejected while sharing resolves is refused, and its file is left alone")
    func removeRemovableMediaRefusesADetachDuringTheResolve() async throws {
        let harness = makeHarness()
        let path = externalPath("media.iso")
        let item = RemovableMediaItem(path: path, readOnly: true)
        let instance = makeInstance(in: harness) { $0.removableMedia = [item] }
        // An Eject from the row's own menu, landing while this removal's
        // resolve is in flight.
        harness.core.afterSharingResolveForTesting = {
            harness.library.editConfiguration(of: instance, as: .hotPlugMedia) { $0.removableMedia = nil }
        }

        let refusal = try await #require(throws: CommandError.self) {
            try await harness.core.removeRemovableMedia(
                .id(instance.id), item: item.id, trashFile: true, consent: .all)
        }

        #expect(refusal.isOperationFailure)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    // MARK: - Start-failure recovery

    @Test("A failed VM takes the start-failed removal both gates admit")
    func removeStartFailedAttachmentOnAFailedVM() async throws {
        let harness = makeHarness()
        let path = externalPath("missing.img")
        let disk = StorageDisk(path: path, label: "Scratch", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeInstance(
            in: harness, phase: .failed(message: "Boot failed."), guestOS: .macOS
        ) {
            $0.storageDisks = [disk, keeper]
            $0.pendingGuestAccount = GuestAccountIntent(
                fullName: "Ada Lovelace", username: "ada", logsInAutomatically: false,
                enablesRemoteLogin: false)
        }

        // A VM at rest with no saved state can be edited, so neither capability
        // blocks the recovery a failed start offered.
        #expect(harness.core.capabilities.accepts(.editStorageDisks, on: instance))
        #expect(harness.core.capabilities.accepts(.editRemovableMedia, on: instance))

        try await harness.core.removeStartFailedAttachment(
            .id(instance.id),
            attachment: StartFailedAttachment(
                verb: .start, kind: .storageDisk, reason: .attachRefused, id: disk.id,
                label: "Scratch",
                message: "could not open"))

        #expect(instance.configuration.storageDisks?.map(\.id) == [keeper.id])
        // The file the start could not open is left exactly where it is.
        #expect(harness.fileSystem.trashedURLs.isEmpty)
        // The removal is the whole verb: the VM is where the failed start left
        // it, and the start the door runs next is an ordinary one.
        #expect(harness.virtualization.startCallCount == 0)
        // Untouched, so the start that follows raises the question itself.
        #expect(instance.configuration.pendingGuestAccount != nil)
    }

    @Test("A resume-failed removal of removable media keeps the saved state for the restore")
    func removeStartFailedRemovableMediaKeepsTheSavedState() async throws {
        let harness = makeHarness()
        let missing = RemovableMediaItem(path: externalPath("gone.dmg"), readOnly: true)
        let keeper = RemovableMediaItem(path: externalPath("keep.iso"), readOnly: true)
        let instance = makeInstance(in: harness, phase: .suspended) {
            $0.removableMedia = [missing, keeper]
        }
        try VMInstanceFixture.writeSaveFile(for: instance)

        try await harness.core.removeStartFailedAttachment(
            .id(instance.id),
            attachment: StartFailedAttachment(
                verb: .resume, kind: .removableMedia, reason: .notFound, id: missing.id,
                label: missing.label, message: "not found"))

        #expect(instance.configuration.removableMedia?.map(\.id) == [keeper.id])
        #expect(instance.hasSaveFile)
        #expect(instance.isSuspended)
        #expect(harness.virtualization.startCallCount == 0)
    }

    @Test("A start-failed removal naming a shared folder that is already gone keeps the saved state")
    func removeStartFailedSharedFolderAlreadyGone() async throws {
        let harness = makeHarness()
        let keeper = SharedDirectory(path: externalPath("Kept"))
        let instance = makeInstance(in: harness, phase: .suspended) {
            $0.sharedDirectories = [keeper]
        }
        try VMInstanceFixture.writeSaveFile(for: instance)

        try await harness.core.removeStartFailedAttachment(
            .id(instance.id),
            attachment: StartFailedAttachment(
                verb: .resume, kind: .sharedDirectory, reason: .notFound, id: UUID(),
                label: "Gone", message: "not found"))

        #expect(instance.configuration.sharedDirectories?.map(\.id) == [keeper.id])
        #expect(instance.hasSaveFile)
        #expect(instance.isSuspended)
    }

    @Test("A start-failed removal that refuses leaves the saved state alone")
    func aRefusedStartFailedRemovalKeepsTheSavedState() async throws {
        let harness = makeHarness()
        let sole = StorageDisk(path: externalPath("missing.img"), label: "Scratch", isInternal: false)
        let instance = makeInstance(in: harness, phase: .suspended) { $0.storageDisks = [sole] }
        try VMInstanceFixture.writeSaveFile(for: instance)

        // A VM keeps at least one storage disk, so this removal is refused.
        await #expect(throws: CommandError.self) {
            try await harness.core.removeStartFailedAttachment(
                .id(instance.id),
                attachment: StartFailedAttachment(
                    verb: .resume, kind: .storageDisk, reason: .attachRefused, id: sole.id,
                    label: "Scratch",
                    message: "could not open"))
        }

        #expect(instance.configuration.storageDisks?.map(\.id) == [sole.id])
        // The refusal is raised before the discard, so the session survives a
        // removal that was never going to happen.
        #expect(instance.hasSaveFile)
        #expect(instance.isSuspended)
    }

    /// The alert the recovery is confirmed from is window-modal, so every other
    /// door stays live behind it: the state the click lands in is not the state
    /// the offer was made in, and the discard is the one step nothing can undo.
    @Test(
        "A start-failed removal the VM can no longer take keeps both the saved state and the entry",
        arguments: [
            PhaseFixture.operating(.bringUp(.guestStart(.restoringSavedState)), from: .suspended),
            .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped),
            .settled(.running(sessionID: VMLifecyclePhaseFixtures.session)),
        ])
    func aStartFailedRemovalRefusedByTheVMsStateKeepsEverything(phase: PhaseFixture) async throws {
        let harness = makeHarness()
        let disk = StorageDisk(path: externalPath("missing.img"), label: "Scratch", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeInstance(in: harness, phase: .suspended) {
            $0.storageDisks = [disk, keeper]
        }
        try VMInstanceFixture.writeSaveFile(for: instance)
        // A bring-up another door issued while the alert was up — the slot is
        // still on disk, and VZ has not finished loading it.
        let placed = phase.phase
        instance.activity.placeForTesting(placed)

        await #expect(throws: CommandError.self) {
            try await harness.core.removeStartFailedAttachment(
                .id(instance.id),
                attachment: StartFailedAttachment(
                    verb: .resume, kind: .storageDisk, reason: .attachRefused, id: disk.id,
                    label: "Scratch",
                    message: "could not open"))
        }

        #expect(instance.hasSaveFile)
        #expect(instance.configuration.storageDisks?.map(\.id) == [disk.id, keeper.id])
        #expect(instance.phase == placed)
    }

    /// The discard is the last thing the recovery does, so everything that can
    /// still refuse — the configuration write included — refuses with the
    /// session and the entry both intact.
    @Test("A start-failed removal whose configuration write fails keeps the saved state")
    func aStartFailedRemovalWhoseWriteFailsKeepsEverything() async throws {
        let harness = makeHarness()
        let disk = StorageDisk(path: externalPath("missing.img"), label: "Scratch", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeInstance(in: harness, phase: .suspended) {
            $0.storageDisks = [disk, keeper]
        }
        try VMInstanceFixture.writeSaveFile(for: instance)
        harness.storage.setSaveConfigurationError(VMStorageError.bundleNotFound(instance.bundleURL))

        await #expect(throws: CommandError.self) {
            try await harness.core.removeStartFailedAttachment(
                .id(instance.id),
                attachment: StartFailedAttachment(
                    verb: .resume, kind: .storageDisk, reason: .attachRefused, id: disk.id,
                    label: "Scratch",
                    message: "could not open"))
        }

        #expect(instance.hasSaveFile)
        #expect(instance.isSuspended)
    }
}
