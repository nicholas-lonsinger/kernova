import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The names the library gives its VMs when bundles store one name: which
/// keeps it, the same whatever order they are read in, and what is stored.
@Suite("VM library names", .serialized, .caseScoped)
@MainActor
struct VMLibraryNamesTests {
    private static let earlier = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let later = earlier.addingTimeInterval(60)

    private static func configuration(_ name: String, createdAt: Date) -> VMConfiguration {
        var configuration = VMConfiguration(
            name: name, guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        configuration.createdAt = createdAt
        return configuration
    }

    /// The identifier whose last byte is `last` and every other byte zero, so
    /// identifiers order as their `last` does.
    private static func id(_ last: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, last))
    }

    @Test(
        "Whatever order entries are listed in, each goes by the same name, and the one added first keeps a name several store"
    )
    func namesAreTheSameInEveryOrder() {
        let claims = [
            // Added to the folder later than the next two, though made earlier.
            VMNameClaim(
                storedName: "Build",
                order: .published(dateAdded: Self.later, createdAt: Self.earlier, id: Self.id(1))),
            // Added together; the identifier comes between them.
            VMNameClaim(
                storedName: "Build",
                order: .published(dateAdded: Self.earlier, createdAt: Self.later, id: Self.id(3))),
            VMNameClaim(
                storedName: "Build",
                order: .published(dateAdded: Self.earlier, createdAt: Self.later, id: Self.id(2))),
            // On a volume that keeps no date added.
            VMNameClaim(
                storedName: "build",
                order: .published(dateAdded: nil, createdAt: Self.earlier, id: Self.id(4))),
            // An arrival, which only this copy lists.
            VMNameClaim(storedName: "BUILD", order: .arriving(createdAt: Self.earlier, id: Self.id(0))),
        ]
        let expected = [
            Self.id(2): "Build", Self.id(3): "Build 2", Self.id(1): "Build 3", Self.id(4): "build 4",
            Self.id(0): "BUILD 5",
        ]

        for permutation in claims.permutations() {
            #expect(VMLibrary.assignedNames(permutation) == expected, "\(permutation.map(\.order.id))")
        }
    }

    @Test(
        "Two bundles storing one name load as two names, the one added to the VMs folder first keeping it, whichever is read first, and the other's bundle stores the name it goes by",
        arguments: [false, true])
    func twoBundlesStoringOneNameLoadAsTwo(olderIsReadFirst: Bool) async throws {
        let storage = MockVMStorageService()
        let folder = try storage.vmsDirectory
        // Made later, so a walk by creation date alone would give it the name.
        let older = Self.configuration("Build", createdAt: Self.later)
        let newer = Self.configuration("build", createdAt: Self.earlier)
        // The library reads bundles in their file names' order.
        let (olderFile, newerFile) = olderIsReadFirst ? ("A", "B") : ("B", "A")
        let olderURL = folder.appendingPathComponent("\(olderFile).kernova", isDirectory: true)
        let newerURL = folder.appendingPathComponent("\(newerFile).kernova", isDirectory: true)
        storage.setConfiguration(older, at: olderURL)
        storage.files.setDateAdded(Self.earlier, at: olderURL)
        storage.setConfiguration(newer, at: newerURL)
        storage.files.setDateAdded(Self.later, at: newerURL)
        let library = makeWiredLibrary(storage: storage)

        await library.loadVMs()

        #expect(
            Dictionary(uniqueKeysWithValues: library.instances.map { ($0.id, $0.name) })
                == [older.id: "Build", newer.id: "build 2"])
        #expect(storage.bundles[olderURL]?.name == "Build")
        #expect(storage.bundles[newerURL]?.name == "build 2")
    }

    @Test("Storing the name a VM goes by leaves a bundle whose stored name changed since it was read")
    func storingANameLeavesARenameMadeSince() throws {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let first = library.registerFixture(name: "Build")
        let second = library.registerFixture(name: "Build")
        let renamed = try #require([first, second].first { $0.name != "Build" })
        // Another copy of Kernova renames it after this one read its bundle.
        var elsewhere = renamed.bundle.configuration
        elsewhere.name = "Lab"
        storage.setConfiguration(elsewhere, at: renamed.bundleURL)

        library.persistAssignedNames()

        #expect(storage.bundles[renamed.bundleURL]?.name == "Lab")
        #expect(renamed.name == "Lab")
    }
}

extension Array {
    /// Every ordering of the elements.
    fileprivate func permutations() -> [[Element]] {
        guard let first else { return [[]] }
        return Array(dropFirst()).permutations().flatMap { rest in
            (0...rest.count).map { index in
                var ordering = rest
                ordering.insert(first, at: index)
                return ordering
            }
        }
    }
}
