import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("ExternalFileReference Tests", .caseScoped)
struct ExternalFileReferenceTests {
    // MARK: - Fixture

    private static let kernelBookmark = FileBookmark(data: Data([0x01]), access: .readWrite)
    private static let initrdBookmark = FileBookmark(data: Data([0x02]), access: .readOnly)
    private static let diskBookmark = FileBookmark(data: Data([0x03]), access: .readWrite)
    private static let mediaBookmark = FileBookmark(data: Data([0x04]), access: .readOnly)
    private static let directoryBookmark = FileBookmark(data: Data([0x05]), access: .readWrite)
    private static let ipswBookmark = FileBookmark(data: Data([0x06]), access: .readOnly)

    /// A configuration with every external field populated at once, each
    /// carrying a distinct sentinel bookmark.
    ///
    /// Not a shape a real VM takes — a Linux kernel boot alongside a macOS
    /// install context — which is the point: one pass exercises every field.
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
        var expected: [UUID: (path: String, bookmark: FileBookmark)] = [:]

        for (index, reference) in config.externalFileReferences.enumerated() {
            let path = "/Volumes/Moved/\(index)"
            let bookmark = FileBookmark(
                data: Data([0xF0, UInt8(index)]), access: index.isMultiple(of: 2) ? .readOnly : .readWrite)
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

    // MARK: - File identities

    /// A reference at `path`, carrying `bookmark` when given.
    ///
    /// The kind is irrelevant to identity, so every case here uses one.
    private func makeReference(path: String, bookmark: Data? = nil) -> ExternalFileReference {
        ExternalFileReference(
            id: UUID(), kind: .storageDisk, label: "Disk", path: path,
            bookmark: bookmark.map { FileBookmark(data: $0, access: .readWrite) }, readOnly: false)
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

    // MARK: - Bookmark creation

    @Test("A file the user can read but not write is bookmarked with read access alone")
    func bookmarksUnwritableFile() throws {
        let scratch = TestScratchDirectory(prefix: "ExternalFileReferenceTests")
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let file = scratch.url.appendingPathComponent("installer.iso")
        try Data("image".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: file.path(percentEncoded: false))

        #expect(SecurityScopedBookmark.make(for: file)?.access == .readOnly)
    }
}
