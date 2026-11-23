import Foundation
import KernovaCommandModel
import KernovaLogging
import KernovaTestSupport
import Synchronization
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// What this copy does with a VM another running copy of Kernova holds while
/// it rests here: an edit is refused inside its coordinated write, the VM
/// claims its identity against every bring-up, and each event-driven refresh
/// marks the hold, clears it, and re-reads what the other copy wrote.
@Suite("Another copy's hold", .caseScoped)
@MainActor
struct VMOtherCopyHoldTests {
    /// An in-memory store that counts each run-lock probe made inside a
    /// coordinated write — so a test can tell the in-write check from
    /// admission's probe, which runs before any write.
    private final class WriteObservingBundleFiles: VMBundleFileAccessing {
        private struct Writes {
            var open = 0
            var probesInside = 0
        }

        let store = InMemoryVMBundleFiles()
        private let writes = Mutex(Writes())

        var probesInsideWrite: Int { writes.withLock { $0.probesInside } }

        func lockBundle(at bundleURL: URL) throws -> (any VMBundleLockHolder)? {
            try store.lockBundle(at: bundleURL)
        }

        func isBundleLockedElsewhere(at bundleURL: URL) throws -> Bool {
            writes.withLock {
                if $0.open > 0 { $0.probesInside += 1 }
            }
            return try store.isBundleLockedElsewhere(at: bundleURL)
        }

        func reading<T>(_ bundleURL: URL, _ body: (any VMBundleFileReading) throws -> T) throws -> T {
            try store.reading(bundleURL, body)
        }

        func writing<T>(
            _ bundleURL: URL, _ key: borrowing VMBundleFileWriteKey,
            _ body: (any VMBundleFileWriting) throws -> T
        ) throws -> T {
            writes.withLock { $0.open += 1 }
            defer { writes.withLock { $0.open -= 1 } }
            return try store.writing(bundleURL, key, body)
        }
    }

    /// A VM at rest whose bundle files are read and written through `access`.
    private func makeInstance(over access: WriteObservingBundleFiles) -> VMInstance {
        let config = VMConfiguration(
            name: "Watched", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let url = VMInstanceFixture.bundleURL(for: config.id)
        access.store.seed(config, at: url)
        return VMInstance(
            bundle: VMBundle.Factory(machineFiles: MockVMBundleMachineFiles(files: access.store))
                .make(VMInstanceFixture.read(url, from: access)),
            phase: .stopped, preferences: makeTestPreferences(),
            hostPasteboard: FakePasteboard(), bundleProducts: .testing, logSink: nil)
    }

    // MARK: - Edits

    @Test("An edit whose bundle another copy takes after admission is refused inside the write")
    func editIsRefusedInsideTheWrite() throws {
        let access = WriteObservingBundleFiles()
        let instance = makeInstance(over: access)
        let url = instance.bundleURL
        let before = try #require(access.store.configuration(at: url))

        #expect(throws: VMAdmissionRefusal(refusal: .heldByAnotherCopy)) {
            try instance.activity.edit(.liveKeys) { permit in
                // Past admission: only the check inside the write can see it.
                access.store.holdElsewhere(url)
                try permit.bundle.commitConfiguration { $0.serialSocketRelayEnabled.toggle() }
            }
        }

        #expect(access.probesInsideWrite == 1)
        #expect(access.store.configuration(at: url) == before)
        #expect(instance.configuration == before)
        #expect(instance.activity.heldByAnotherCopy)
    }

    // MARK: - Identity

    nonisolated private static let sharedMAC = "02:4b:4e:56:00:01"

    /// What two twins share.
    enum Twinning: Sendable, CustomTestStringConvertible {
        case macAddress
        case machineIdentity
        /// Both — refused on the MAC address, which no override waives.
        case both

        /// What the second twin's start is refused on.
        /// A shared machine identity is answered before a MAC address.
        var reason: ConflictReason {
            self == .macAddress ? .macAddress : .machineIdentity(overrideSettingOn: false)
        }

        var testDescription: String {
            switch self {
            case .macAddress: "MAC address"
            case .machineIdentity: "machine identity"
            case .both: "machine identity and MAC address"
            }
        }
    }

    /// Makes the `index`th VM of a pair sharing what `twinning` names.
    nonisolated private static func twin(
        _ twinning: Twinning, index: UInt8, identity: Data
    ) -> (inout VMConfiguration) -> Void {
        { config in
            config.networkEnabled = true
            switch twinning {
            case .macAddress:
                config.macAddress = sharedMAC
            case .machineIdentity:
                config.genericMachineIdentifierData = identity
                config.macAddress = String(format: "02:4b:4e:56:01:%02x", index)
            case .both:
                config.genericMachineIdentifierData = identity
                config.macAddress = sharedMAC
            }
        }
    }

    @Test(
        "A twin of a VM another copy holds is refused, naming the source",
        arguments: [Twinning.macAddress, .machineIdentity, .both])
    func twinOfAHeldVMIsRefused(twinning: Twinning) {
        let label = twinning.testDescription
        let reason = twinning.reason
        let storage = MockVMStorageService()
        let preferences = makeTestPreferences()
        let library = makeWiredLibrary(storage: storage, preferences: preferences)
        let identity = Data([7, 7, 7])
        let source = library.registerFixture(
            name: "Source", preferences: preferences,
            mutate: Self.twin(twinning, index: 1, identity: identity))
        let copy = library.registerFixture(
            name: "Copy", preferences: preferences,
            mutate: Self.twin(twinning, index: 2, identity: identity))
        storage.files.holdElsewhere(source.bundleURL)

        let decision = copy.activity.decide(.start(recovery: false), posture: .commit)

        guard case .refuse(.identityConflict(let conflict)) = decision else {
            Issue.record("\(label): decided \(decision)")
            return
        }
        #expect(conflict.other === source, "\(label)")
        #expect(conflict.reason == reason, "\(label)")
        #expect(source.activity.heldByAnotherCopy, "\(label)")

        // The check caught the source up first, so a hold that ended admits.
        storage.files.releaseElsewhere(source.bundleURL)
        #expect(copy.activity.decide(.start(recovery: false), posture: .commit) == .admit, "\(label)")
        #expect(!source.activity.heldByAnotherCopy, "\(label)")
    }
}
