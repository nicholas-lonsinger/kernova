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

    // MARK: - File identities

    /// A reference at `path`, carrying `bookmark` when given.
    ///
    /// The kind is irrelevant to identity, so every case here uses one.
    private func makeReference(path: String, bookmark: Data? = nil) -> ExternalFileReference {
        ExternalFileReference(
            id: UUID(), kind: .storageDisk, label: "Disk", path: path, bookmark: bookmark)
    }

    @Test("A reference with no bookmark is identified by its stored path alone")
    func identitiesWithoutBookmark() {
        let references = [makeReference(path: "/Volumes/External/data.img")]
        #expect(references.fileIdentities(resolvedTargets: [:]) == ["/Volumes/External/data.img"])
    }

    @Test("A bookmark pointing elsewhere adds the resolved target to the identity")
    func identitiesIncludeResolvedTarget() {
        let bookmark = Data([0xA1])
        let references = [makeReference(path: "/Volumes/External/old.img", bookmark: bookmark)]

        // The union is what matches a sibling still holding the pre-move path.
        #expect(
            references.fileIdentities(resolvedTargets: [bookmark: "/Volumes/External/new.img"])
                == ["/Volumes/External/old.img", "/Volumes/External/new.img"])
    }

    @Test("A bookmark resolving to the stored path yields one identity")
    func identitiesCollapseWhenBookmarkAgrees() {
        let bookmark = Data([0xA2])
        let references = [makeReference(path: "/Volumes/External/data.img", bookmark: bookmark)]
        #expect(
            references.fileIdentities(resolvedTargets: [bookmark: "/Volumes/External/data.img"])
                == ["/Volumes/External/data.img"])
    }

    @Test("A bookmark absent from the resolutions falls back to the stored path")
    func identitiesFallBackWhenResolutionFailed() {
        let references = [makeReference(path: "/Volumes/External/data.img", bookmark: Data([0xA3]))]
        #expect(references.fileIdentities(resolvedTargets: [:]) == ["/Volumes/External/data.img"])
    }

    @Test("A decomposed resolved name matches the precomposed stored one")
    func identitiesCanonicalizeUnicodeForm() {
        let bookmark = Data([0xA4])
        let precomposed = "/Users/me/Cafe\u{0301}".precomposedStringWithCanonicalMapping
        let decomposed = precomposed.decomposedStringWithCanonicalMapping
        let references = [makeReference(path: precomposed, bookmark: bookmark)]

        // APFS hands back the decomposed form of a name the panel stored
        // precomposed; that is the same file, not a second identity.
        #expect(references.fileIdentities(resolvedTargets: [bookmark: decomposed]).count == 1)
    }

    @Test("A trailing slash and a redundant component don't split an identity")
    func identitiesCanonicalizePathForm() {
        let bookmark = Data([0xA5])
        let references = [makeReference(path: "/Users/me/Projects/", bookmark: bookmark)]
        #expect(
            references.fileIdentities(resolvedTargets: [bookmark: "/Users/me/./Projects"])
                == ["/Users/me/Projects"])
    }

    @Test("Identities across references are unioned")
    func identitiesUnionEveryReference() {
        let references = [
            makeReference(path: "/Users/me/vmlinuz"),
            makeReference(path: "/Users/me/initrd.img"),
        ]
        #expect(
            references.fileIdentities(resolvedTargets: [:])
                == ["/Users/me/vmlinuz", "/Users/me/initrd.img"])
    }

    // MARK: - Sharing match

    @Test("A VM whose bookmark resolved to the file is shared despite a stale stored path")
    func sharingMatchesOnResolvedTarget() {
        // The subject healed to the file's new home; the sibling never booted
        // since the move, so its config still names the old one.
        let subject: Set<String> = ["/Volumes/External/new.img"]
        let sibling = [makeReference(path: "/Volumes/External/old.img", bookmark: Data([0xB1]))]
            .fileIdentities(resolvedTargets: [Data([0xB1]): "/Volumes/External/new.img"])

        #expect(
            VMCommandCore.sharingVMNames(
                matching: subject, among: [(name: "Sibling", identities: sibling)]) == ["Sibling"])
    }

    @Test("Disjoint identities share nothing")
    func sharingIgnoresUnrelatedFiles() {
        #expect(
            VMCommandCore.sharingVMNames(
                matching: ["/Users/me/a.img"],
                among: [(name: "Other", identities: ["/Users/me/b.img"])]
            ).isEmpty)
    }

    @Test("A VM with no external references shares nothing")
    func sharingIgnoresReferenceLessVMs() {
        #expect(
            VMCommandCore.sharingVMNames(
                matching: ["/Users/me/a.img"], among: [(name: "Bare", identities: [])]
            ).isEmpty)
    }

    @Test("Matching names come back in the order the candidates were given")
    func sharingPreservesLibraryOrder() {
        let shared: Set<String> = ["/Users/me/shared.iso"]
        #expect(
            VMCommandCore.sharingVMNames(
                matching: shared,
                among: [
                    (name: "First", identities: shared),
                    (name: "Unrelated", identities: ["/Users/me/other.iso"]),
                    (name: "Second", identities: shared),
                ]) == ["First", "Second"])
    }
}
