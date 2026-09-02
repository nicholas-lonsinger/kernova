import Foundation
import Testing

@testable import Kernova

@Suite("ExternalFileReference Tests", .admissionGated)
struct ExternalFileReferenceTests {
    // MARK: - Fixture

    private static let kernelBookmark = Data([0x01])
    private static let initrdBookmark = Data([0x02])
    private static let diskBookmark = Data([0x03])
    private static let mediaBookmark = Data([0x04])
    private static let directoryBookmark = Data([0x05])
    private static let ipswBookmark = Data([0x06])

    /// A configuration with every external field populated at once, each
    /// carrying a distinct sentinel bookmark.
    ///
    /// Not a shape a real VM takes — a Linux kernel boot alongside a macOS
    /// install context — which is the point: one pass exercises every field,
    /// and ``fixtureCoversEveryKind()`` holds this to every kind.
    private func makeFullyPopulatedConfig() -> VMConfiguration {
        var config = VMConfiguration(name: "Externals", guestOS: .linux, bootMode: .linuxKernel)
        config.kernelPath = "/Users/me/vmlinuz"
        config.kernelBookmark = Self.kernelBookmark
        config.initrdPath = "/Users/me/initrd.img"
        config.initrdBookmark = Self.initrdBookmark
        config.storageDisks = [
            StorageDisk(path: "Disk.asif", label: "Main Disk", isInternal: true),
            StorageDisk(
                path: "/Volumes/External/data.img", label: "Data", bookmark: Self.diskBookmark),
        ]
        config.removableMedia = [
            RemovableMediaItem(
                path: "/Users/me/installer.iso", label: "Installer",
                bookmark: Self.mediaBookmark)
        ]
        config.sharedDirectories = [
            SharedDirectory(path: "/Users/me/Projects", bookmark: Self.directoryBookmark)
        ]
        config.installContext = MacOSInstallContext(
            source: .localFile,
            localIPSWPath: "/Users/me/restore.ipsw",
            localIPSWBookmark: Self.ipswBookmark)
        return config
    }

    // MARK: - Fixture completeness

    @Test("The fixture populates every reference kind")
    func fixtureCoversEveryKind() {
        let projected = Set(makeFullyPopulatedConfig().externalFileReferences.map(\.kind))
        // What makes the rest of this suite exhaustive: the shape, heal and
        // bookmark assertions all run off this one fixture, so a new `Kind`
        // fails here until the fixture grows an entry feeding it.
        #expect(projected == Set(ExternalFileReference.Kind.allCases))
    }

    @Test("Every bookmark the fixture stores is reachable through the projection")
    func projectionCoversEveryStoredBookmark() {
        let config = makeFullyPopulatedConfig()
        let stored = Set(Self.storedBookmarks(in: config))
        let projected = Set(config.externalFileReferences.compactMap(\.bookmark))

        #expect(stored == projected)
        #expect(stored.count == 6)
    }

    /// Every non-nil bookmark `Data` reachable from `value`, found by property
    /// name (`bookmark`, or any label containing `Bookmark`) rather than by a
    /// hand-written list of fields.
    ///
    /// Scope: this catches a bookmark-carrying field the fixture *populates*
    /// and the projection drops. A field the fixture leaves nil reflects as an
    /// empty optional and is invisible here — ``fixtureCoversEveryKind()`` is
    /// what forces the fixture to grow.
    private static func storedBookmarks(in value: Any, label: String? = nil) -> [Data] {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return [] }
            return storedBookmarks(in: wrapped, label: label)
        }
        if let label, label.localizedCaseInsensitiveContains("bookmark"),
            let bookmark = value as? Data
        {
            return [bookmark]
        }
        return mirror.children.flatMap { storedBookmarks(in: $0.value, label: $0.label) }
    }

    // MARK: - Shape

    @Test("The projection yields one reference per populated external field")
    func projectionShape() {
        let references = makeFullyPopulatedConfig().externalFileReferences

        #expect(
            references.map(\.kind) == [
                .kernel, .initrd, .storageDisk, .removableMedia, .sharedDirectory, .localIPSW,
            ])
        #expect(
            references.map(\.label) == [
                "Kernel", "Initial RAM Disk", "Data", "Installer", "Projects", "Installer Image",
            ])
        #expect(
            references.map(\.path) == [
                "/Users/me/vmlinuz", "/Users/me/initrd.img", "/Volumes/External/data.img",
                "/Users/me/installer.iso", "/Users/me/Projects", "/Users/me/restore.ipsw",
            ])
        #expect(
            references.map(\.bookmark) == [
                Self.kernelBookmark, Self.initrdBookmark, Self.diskBookmark, Self.mediaBookmark,
                Self.directoryBookmark, Self.ipswBookmark,
            ])
    }

    @Test("An internal disk is never projected")
    func internalDiskIsAbsent() {
        let config = makeFullyPopulatedConfig()
        #expect(!config.externalFileReferences.contains { $0.path == "Disk.asif" })
    }

    @Test("A configuration with no external fields projects nothing")
    func emptyConfigurationProjectsNothing() {
        let config = VMConfiguration(name: "Bare", guestOS: .macOS, bootMode: .macOS)
        #expect(config.externalFileReferences.isEmpty)
    }

    // MARK: - Heal round-trip

    @Test("Healing every projected reference writes back to the field it came from")
    func healWritesBackEveryKind() {
        var config = makeFullyPopulatedConfig()
        var expected: [UUID: (path: String, bookmark: Data)] = [:]

        for (index, reference) in config.externalFileReferences.enumerated() {
            let path = "/Volumes/Moved/\(index)"
            let bookmark = Data([0xF0, UInt8(index)])
            expected[reference.id] = (path, bookmark)
            config.healExternalReference(reference, movedTo: path, bookmark: bookmark)
        }

        let healed = config.externalFileReferences
        #expect(healed.count == expected.count)
        for reference in healed {
            #expect(reference.path == expected[reference.id]?.path)
            #expect(reference.bookmark == expected[reference.id]?.bookmark)
        }
    }

    @Test("Healing a reference whose list entry is gone changes nothing")
    func healOfRemovedEntryIsNoOp() throws {
        var config = makeFullyPopulatedConfig()
        let disk = try #require(config.externalFileReferences.first { $0.kind == .storageDisk })
        config.storageDisks = config.storageDisks?.filter(\.isInternal)
        let before = config

        config.healExternalReference(disk, movedTo: "/Volumes/Moved/gone", bookmark: Data([0x07]))
        #expect(config == before)
    }

    // MARK: - Stable identity

    @Test("The singleton kinds keep one id across projections and differ from each other")
    func singletonIDsAreStableAndDistinct() {
        let config = makeFullyPopulatedConfig()
        let first = config.externalFileReferences
        let second = config.externalFileReferences

        func id(
            _ kind: ExternalFileReference.Kind, in references: [ExternalFileReference]
        ) -> UUID? {
            references.first { $0.kind == kind }?.id
        }

        #expect(id(.kernel, in: first) == id(.kernel, in: second))
        #expect(id(.initrd, in: first) == id(.initrd, in: second))
        #expect(id(.kernel, in: first) != id(.initrd, in: first))
    }

    // MARK: - bookmarksByPath

    @Test("bookmarksByPath maps each external path to its bookmark")
    func bookmarksByPathMapsEachPath() {
        var config = VMConfiguration(name: "Test", guestOS: .linux, bootMode: .efi)
        let diskBookmark = Data([0xAA])
        config.storageDisks = [
            StorageDisk(path: "Disk.asif", isInternal: true),
            StorageDisk(
                path: "/Volumes/External/data.img", isInternal: false, bookmark: diskBookmark),
        ]
        config.removableMedia = [
            RemovableMediaItem(path: "/Users/me/installer.iso")
        ]

        let refs = config.externalFileReferences.bookmarksByPath
        #expect(Set(refs.keys) == ["/Volumes/External/data.img", "/Users/me/installer.iso"])
        #expect(refs["/Volumes/External/data.img"] == diskBookmark)
        #expect(refs["/Users/me/installer.iso"] == Data?.none)
    }

    @Test("A non-nil bookmark wins when the same path appears twice")
    func bookmarksByPathPrefersNonNilBookmark() {
        var config = VMConfiguration(name: "Test", guestOS: .linux, bootMode: .efi)
        let bookmark = Data([0xBB])
        config.storageDisks = [
            StorageDisk(path: "/Users/me/shared.iso", isInternal: false)
        ]
        config.removableMedia = [
            RemovableMediaItem(path: "/Users/me/shared.iso", bookmark: bookmark)
        ]

        #expect(config.externalFileReferences.bookmarksByPath["/Users/me/shared.iso"] == bookmark)
    }

    @Test("bookmarksByPath is empty when there are no external references")
    func bookmarksByPathEmpty() {
        let config = VMConfiguration(name: "Test", guestOS: .linux, bootMode: .efi)
        #expect(config.externalFileReferences.bookmarksByPath.isEmpty)
    }
}
