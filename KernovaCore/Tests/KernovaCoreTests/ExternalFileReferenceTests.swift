import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("ExternalFileReference Tests", .caseScoped)
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
        var config = VMConfiguration(
            name: "Externals", guestOS: .linux, bootMode: .linuxKernel, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
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
        var config = VMConfiguration(
            name: "Test", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
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

    // MARK: - File identities

    /// A reference at `path`, carrying `bookmark` when given.
    ///
    /// The kind is irrelevant to identity, so every case here uses one.
    private func makeReference(path: String, bookmark: Data? = nil) -> ExternalFileReference {
        ExternalFileReference(
            id: UUID(), kind: .storageDisk, label: "Disk", path: path, bookmark: bookmark)
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

    @Test("A trailing slash and a redundant component don't split an identity")
    func identitiesCanonicalizePathForm() {
        let bookmark = Data([0xA5])
        let references = [makeReference(path: "/Users/me/Projects/", bookmark: bookmark)]
        #expect(
            references.fileIdentities(resolvedTargets: [bookmark: "/Users/me/./Projects"])
                == ["/Users/me/Projects"])
    }

    @Test("Each distinct bookmark blob is resolved once, successes and failures alike")
    func resolvedTargetsResolveEachBlobOnce() {
        let live = Data([0xC1])
        let dead = Data([0xC2])
        let references = [
            makeReference(path: "/Volumes/External/a.img", bookmark: live),
            makeReference(path: "/Volumes/External/b.img", bookmark: live),
            makeReference(path: "/Volumes/External/c.img", bookmark: dead),
            makeReference(path: "/Volumes/External/d.img", bookmark: dead),
            makeReference(path: "/Volumes/External/e.img"),
        ]

        var attempted: [Data] = []
        let targets = references.resolvedTargets { blob in
            attempted.append(blob)
            return blob == live ? "/Volumes/External/moved.img" : nil
        }

        // A dead blob is memoized like a live one — otherwise every reference
        // carrying it pays the resolution again and re-logs the failure.
        #expect(attempted == [live, dead])
        #expect(targets == [live: "/Volumes/External/moved.img"])
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

    // MARK: - Kind predicates

    @Test("Existence monitoring covers every kind a settings row can badge")
    func existenceMonitoringCoversTheBadgedKinds() {
        // The three kinds the settings lists render a row for, each of which
        // shows the missing-file badge when its file goes away.
        #expect(ExternalFileReference.Kind.storageDisk.isExistenceMonitored)
        #expect(ExternalFileReference.Kind.removableMedia.isExistenceMonitored)
        #expect(ExternalFileReference.Kind.sharedDirectory.isExistenceMonitored)

        // A kernel and an initrd have System-panel rows that state no existence,
        // and a local IPSW has no row at all.
        #expect(!ExternalFileReference.Kind.kernel.isExistenceMonitored)
        #expect(!ExternalFileReference.Kind.initrd.isExistenceMonitored)
        #expect(!ExternalFileReference.Kind.localIPSW.isExistenceMonitored)
    }
}
