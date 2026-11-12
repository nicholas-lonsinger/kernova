import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMLiveIdentities Tests", .caseScoped)
@MainActor
struct VMLiveIdentitiesTests {
    @Test("A bring-up in flight holds its identity against its twin")
    func aBringUpInFlightHoldsItsIdentity() throws {
        let preferences = makeTestPreferences()
        let identity = Data([3, 1, 4])
        let library = makeWiredLibrary(preferences: preferences)
        let first = library.registerFixture(name: "First", preferences: preferences) {
            $0.genericMachineIdentifierData = identity
        }
        let second = library.registerFixture(name: "Second", preferences: preferences) {
            $0.genericMachineIdentifierData = identity
        }

        first.activity.placeForTesting(
            .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped))

        // No session exists yet on either side: the operation alone is what
        // makes the first live to the second's check.
        guard
            case .refuse(.identityConflict(let conflict)) = second.activity.decide(
                .start(recovery: false), posture: .commit)
        else {
            Issue.record("the twin's start was not refused on its identity")
            return
        }
        #expect(conflict.other === first)
        #expect(conflict.reason == .machineIdentity(overrideSettingOn: false))
        #expect(second.phase == .stopped)
        withExtendedLifetime(library) {}
    }

    /// One row of the decision: the setting, the standing choice not to be
    /// asked, what the request brings, and whether the twin also shares the
    /// MAC address on one network.
    struct Row: Sendable, CustomTestStringConvertible {
        let allowsOverride: Bool
        var questionDismissed = false
        let override: VMIdentityOverride
        let sharesMAC: Bool
        /// `nil` admits; otherwise the reason refused and whether it asks to
        /// start anyway — which a MAC address never does.
        let expected: (reason: ConflictReason, asks: Bool)?

        var testDescription: String {
            "setting \(allowsOverride ? "on" : "off"), question \(questionDismissed ? "dismissed" : "asked"), "
                + "\(override), MAC \(sharesMAC ? "shared" : "own")"
        }
    }

    /// A shared machine ID's refusal, with the setting that offers starting
    /// anyway off and on.
    nonisolated static let identityOff = ConflictReason.machineIdentity(overrideSettingOn: false)
    nonisolated static let identityOn = ConflictReason.machineIdentity(overrideSettingOn: true)

    nonisolated static let rows: [Row] = [
        Row(allowsOverride: false, override: .unavailable, sharesMAC: false, expected: (identityOff, false)),
        Row(allowsOverride: false, override: .askable, sharesMAC: false, expected: (identityOff, false)),
        Row(allowsOverride: false, override: .confirmed, sharesMAC: false, expected: (identityOff, false)),
        Row(allowsOverride: true, override: .unavailable, sharesMAC: false, expected: (identityOn, false)),
        Row(allowsOverride: true, override: .askable, sharesMAC: false, expected: (identityOn, true)),
        Row(allowsOverride: true, override: .confirmed, sharesMAC: false, expected: nil),
        Row(allowsOverride: false, override: .unavailable, sharesMAC: true, expected: (identityOff, false)),
        Row(allowsOverride: false, override: .confirmed, sharesMAC: true, expected: (identityOff, false)),
        Row(allowsOverride: true, override: .askable, sharesMAC: true, expected: (identityOn, true)),
        Row(allowsOverride: true, override: .confirmed, sharesMAC: true, expected: (.macAddress, false)),
        // A boot chained after the call that asked keeps the confirmation and asks nothing.
        Row(allowsOverride: true, override: .confirmed.unattended, sharesMAC: false, expected: nil),
        Row(allowsOverride: true, override: .confirmed.unattended, sharesMAC: true, expected: (.macAddress, false)),
        Row(allowsOverride: true, override: .askable.unattended, sharesMAC: false, expected: (identityOn, false)),
        // The standing choice not to be asked waives it for every request, the
        // unaskable ones included — but only while the setting is on, and
        // never a MAC address.
        Row(
            allowsOverride: true, questionDismissed: true, override: .unavailable, sharesMAC: false,
            expected: nil),
        Row(
            allowsOverride: true, questionDismissed: true, override: .askable, sharesMAC: false,
            expected: nil),
        Row(
            allowsOverride: true, questionDismissed: true, override: .askable.unattended, sharesMAC: false,
            expected: nil),
        Row(
            allowsOverride: true, questionDismissed: true, override: .unavailable, sharesMAC: true,
            expected: (.macAddress, false)),
        Row(
            allowsOverride: false, questionDismissed: true, override: .askable, sharesMAC: false,
            expected: (identityOff, false)),
    ]

    @Test(
        "A shared machine ID is answered first and waived only, while the setting is on, by a confirmed override or the standing choice not to be asked; a MAC address after it, never waived",
        arguments: rows)
    func decisionTable(row: Row) {
        let preferences = makeTestPreferences()
        preferences.allowsDuplicateMachineIDOverride = row.allowsOverride
        preferences.duplicateMachineIDQuestionDismissed = row.questionDismissed
        let identity = Data([2, 7, 1, 8])
        let library = makeWiredLibrary(preferences: preferences)
        let live = library.registerFixture(
            name: "Live", phase: .running(sessionID: UUID()), preferences: preferences
        ) {
            $0.genericMachineIdentifierData = identity
            $0.networkEnabled = true
            $0.macAddress = "02:4b:4e:56:0a:01"
        }
        let twin = library.registerFixture(name: "Twin", preferences: preferences) {
            $0.genericMachineIdentifierData = identity
            $0.networkEnabled = true
            $0.macAddress = row.sharesMAC ? "02:4b:4e:56:0a:01" : "02:4b:4e:56:0a:02"
        }

        let decision = twin.activity.decide(
            .start(recovery: false), posture: .commit, identity: row.override)

        switch (decision, row.expected) {
        case (.admit, nil):
            break
        case (.refuse(.identityConflict(let conflict)), let expected?):
            #expect(conflict.other === live)
            #expect(conflict.reason == expected.reason)
            #expect(conflict.asks == expected.asks)
            #expect(conflict.configuration == twin.configuration)
        default:
            Issue.record("decided \(decision)")
        }
        withExtendedLifetime(library) {}
    }

    // MARK: - Disk Images

    /// How the VM holding a disk image is placed when another starts with it.
    enum HolderState: Sendable, CaseIterable, CustomTestStringConvertible {
        case running, bringingUp, heldByAnotherCopy, stopped, suspended

        /// Whether a VM so placed has its disk images open.
        var claims: Bool {
            switch self {
            case .running, .bringingUp, .heldByAnotherCopy: true
            case .stopped, .suspended: false
            }
        }

        var testDescription: String {
            switch self {
            case .running: "running"
            case .bringingUp: "bring-up in flight"
            case .heldByAnotherCopy: "held by another copy"
            case .stopped: "stopped"
            case .suspended: "suspended"
            }
        }
    }

    /// The external disk-image kinds a configuration lists.
    enum ImageKind: Sendable, CaseIterable, CustomTestStringConvertible {
        case removableMedia, storageDisk

        /// Lists the image at `path` as this kind, labelled `label`.
        func attach(_ path: String, readOnly: Bool, label: String, to config: inout VMConfiguration) {
            switch self {
            case .removableMedia:
                config.removableMedia = [RemovableMediaItem(path: path, readOnly: readOnly, label: label)]
            case .storageDisk:
                config.storageDisks = [
                    StorageDisk(
                        id: UUID(), path: path, readOnly: readOnly, label: label, isInternal: false,
                        kind: .virtio)
                ]
            }
        }

        var testDescription: String { self == .removableMedia ? "removable media" : "storage disk" }
    }

    struct DiskImageRow: Sendable, CustomTestStringConvertible {
        let holderState: HolderState
        let holderKind: ImageKind
        let holderReadOnly: Bool
        let candidateKind: ImageKind
        let candidateReadOnly: Bool

        var testDescription: String {
            "holder \(holderState) \(holderKind) \(holderReadOnly ? "read-only" : "writable"), "
                + "candidate \(candidateKind) \(candidateReadOnly ? "read-only" : "writable")"
        }
    }

    nonisolated static let diskImageRows: [DiskImageRow] = HolderState.allCases.flatMap { state in
        ImageKind.allCases.flatMap { holderKind in
            ImageKind.allCases.flatMap { candidateKind in
                [false, true].flatMap { holderReadOnly in
                    [false, true].map { candidateReadOnly in
                        DiskImageRow(
                            holderState: state, holderKind: holderKind, holderReadOnly: holderReadOnly,
                            candidateKind: candidateKind, candidateReadOnly: candidateReadOnly)
                    }
                }
            }
        }
    }

    @Test(
        "A start naming a disk image another VM has open is refused, unless both have it read-only",
        arguments: diskImageRows)
    func diskImageSweep(row: DiskImageRow) {
        let storage = MockVMStorageService()
        let preferences = makeTestPreferences()
        let library = makeWiredLibrary(storage: storage, preferences: preferences)
        let path = "/Volumes/Shared/w.img"
        let holderPhase: VMLifecyclePhase =
            switch row.holderState {
            case .running: .running(sessionID: UUID())
            case .suspended: .suspended
            case .bringingUp, .heldByAnotherCopy, .stopped: .stopped
            }
        let holder = library.registerFixture(name: "Holder", phase: holderPhase, preferences: preferences) {
            row.holderKind.attach(path, readOnly: row.holderReadOnly, label: "There", to: &$0)
        }
        switch row.holderState {
        case .bringingUp:
            holder.activity.placeForTesting(
                .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped))
        case .heldByAnotherCopy:
            storage.files.holdElsewhere(holder.bundleURL)
        case .running, .stopped, .suspended:
            break
        }
        let candidate = library.registerFixture(name: "Candidate", preferences: preferences) {
            row.candidateKind.attach(path, readOnly: row.candidateReadOnly, label: "Here", to: &$0)
        }

        let decision = candidate.activity.decide(.start(recovery: false), posture: .commit)

        let refused = row.holderState.claims && !(row.holderReadOnly && row.candidateReadOnly)
        switch decision {
        case .admit where !refused:
            break
        case .refuse(.identityConflict(let conflict)) where refused:
            #expect(conflict.other === holder)
            #expect(
                conflict.reason
                    == .diskImage(
                        label: "Here", writableHere: !row.candidateReadOnly,
                        writableThere: !row.holderReadOnly))
            #expect(!conflict.asks)
        default:
            Issue.record("decided \(decision)")
        }
        withExtendedLifetime(library) {}
    }

    @Test("A guest-agent installer entry is neither a claim nor a candidate")
    func installerEntriesNeverConflict() throws {
        let preferences = makeTestPreferences()
        let library = makeWiredLibrary(preferences: preferences)
        let installer = try #require(AppBundleProducts.testing.guestAgents.macOSInstallerDiskImageURL)
            .path(percentEncoded: false)
        // Writable on both sides, so only the exclusion admits the start.
        let entry: (inout VMConfiguration) -> Void = {
            $0.removableMedia = [RemovableMediaItem(path: installer, readOnly: false, label: "Kernova Guest Agent")]
        }
        _ = library.registerFixture(
            name: "Holder", phase: .running(sessionID: UUID()), preferences: preferences, mutate: entry)
        let candidate = library.registerFixture(name: "Candidate", preferences: preferences, mutate: entry)

        #expect(candidate.activity.decide(.start(recovery: false), posture: .commit) == .admit)
        withExtendedLifetime(library) {}
    }

    @Test("A disk image is answered before a shared machine identity, so nothing is asked")
    func diskImageIsAnsweredBeforeMachineIdentity() {
        let preferences = makeTestPreferences()
        preferences.allowsDuplicateMachineIDOverride = true
        let identity = Data([1, 6, 1, 8])
        let library = makeWiredLibrary(preferences: preferences)
        let path = "/Volumes/Shared/w.img"
        let live = library.registerFixture(
            name: "Live", phase: .running(sessionID: UUID()), preferences: preferences
        ) {
            $0.genericMachineIdentifierData = identity
            $0.removableMedia = [RemovableMediaItem(path: path, readOnly: false, label: "W")]
        }
        let twin = library.registerFixture(name: "Twin", preferences: preferences) {
            $0.genericMachineIdentifierData = identity
            $0.removableMedia = [RemovableMediaItem(path: path, readOnly: false, label: "W")]
        }

        let decision = twin.activity.decide(.start(recovery: false), posture: .commit, identity: .askable)

        guard case .refuse(.identityConflict(let conflict)) = decision else {
            Issue.record("decided \(decision)")
            return
        }
        #expect(conflict.other === live)
        #expect(conflict.reason == .diskImage(label: "W", writableHere: true, writableThere: true))
        #expect(!conflict.asks)
        withExtendedLifetime(library) {}
    }

    @Test("A running VM's disk image is matched at the path its bookmark resolved to")
    func diskImageMatchesTheHoldersResolvedPath() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "VMLiveIdentitiesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Named as a bookmark resolves it, through no symlink such as /var.
        let directory = scratch.resolvingSymlinksInPath()
        let picked = directory.appending(path: "picked.img")
        try Data(repeating: 0, count: 512).write(to: picked)
        let bookmark = try #require(SecurityScopedBookmark.make(for: picked))
        let moved = directory.appending(path: "moved.img")
        try FileManager.default.moveItem(at: picked, to: moved)

        let preferences = makeTestPreferences()
        let library = makeWiredLibrary(preferences: preferences)
        let holder = library.registerFixture(
            name: "Holder", phase: .running(sessionID: UUID()), preferences: preferences
        ) {
            $0.removableMedia = [
                RemovableMediaItem(
                    path: picked.path(percentEncoded: false), readOnly: false, label: "Picked",
                    bookmark: bookmark)
            ]
        }
        // The session opens the bookmark as a boot does, so it resolves to the moved file.
        holder.beginSessionContextForTesting()
        let naming = { (url: URL) in
            library.registerFixture(name: url.lastPathComponent, preferences: preferences) {
                $0.removableMedia = [
                    RemovableMediaItem(path: url.path(percentEncoded: false), readOnly: false, label: "Here")
                ]
            }
        }
        let atResolved = naming(moved)
        let elsewhere = naming(directory.appending(path: "other.img"))

        guard
            case .refuse(.identityConflict(let conflict)) = atResolved.activity.decide(
                .start(recovery: false), posture: .commit)
        else {
            Issue.record("a start naming the resolved path was admitted")
            return
        }
        #expect(conflict.other === holder)
        #expect(elsewhere.activity.decide(.start(recovery: false), posture: .commit) == .admit)
        withExtendedLifetime(library) {}
    }
}
