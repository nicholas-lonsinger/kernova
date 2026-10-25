import AppleArchive
import Darwin
import Foundation
import KernovaSynchronization
import KernovaTestSupport
import System
import Testing

@testable import KernovaKit

/// The receiving side's extract on its own: what each entry becomes, which
/// entries it refuses and how, and what each attribute does. Round-trip
/// fidelity through the sender's own archives is `ClipboardArchiveStreamTests`.
@Suite("ClipboardArchiveExtraction", .caseScoped)
struct ClipboardArchiveExtractionTests {
    private let scratch = TestScratchDirectory(prefix: "archive-extract")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    /// An empty directory to extract into, alone in a directory of its own so
    /// anything written beside it shows.
    private func makeDestination() throws -> URL {
        let destination = scratch.url.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }

    private static let creation = timespec(tv_sec: 981_173_106, tv_nsec: 111_111_111)
    private static let modification = timespec(tv_sec: 1_013_000_000, tv_nsec: 222_222_222)

    /// `entry` carrying the test's creation and modification times.
    private func timed(_ entry: RawArchiveEntry) -> RawArchiveEntry {
        var entry = entry
        entry.creation = Self.creation
        entry.modification = Self.modification
        return entry
    }

    private func expectTimes(_ path: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let status = try linkStatus(path)
        #expect(sameInstant(status.st_mtimespec, Self.modification), "mtime of \(path)", sourceLocation: sourceLocation)
        #expect(
            sameInstant(status.st_birthtimespec, Self.creation), "birth time of \(path)", sourceLocation: sourceLocation
        )
    }

    /// The groups this process is in.
    private static func memberGroups() -> Set<gid_t> {
        var groups = [gid_t](repeating: 0, count: Int(NGROUPS_MAX))
        let count = getgroups(Int32(groups.count), &groups)
        return Set(groups.prefix(Int(max(0, count)))).union([getegid()])
    }

    /// A group this process is not in.
    private static func foreignGroup() throws -> gid_t {
        let members = memberGroups()
        return try #require((0..<gid_t(1000)).first { !members.contains($0) })
    }

    // MARK: - Entries

    /// A blob far larger than one read is taken in pieces, each written in
    /// full before the next is read.
    @Test("a file larger than one read lands byte for byte")
    func largeFileLandsWhole() throws {
        let destination = try makeDestination()
        var generator = SystemRandomNumberGenerator()
        let payload = Data(
            (0..<(2 * ClipboardArchiveCodec.fileReadBlockSize + 4097)).map { _ in
                UInt8.random(in: 0...255, using: &generator)
            })
        var entry = RawArchiveEntry.file("big.bin")
        entry.data = payload

        #expect(extractFailure(try rawArchive([.root(), entry]), into: destination) == nil)
        #expect(try Data(contentsOf: destination.appendingPathComponent("big.bin")) == payload)
    }

    @Test("a tree whose paths run past PATH_MAX lands whole, and its staged copy is removed")
    func treePastPathMaxRoundTrips() throws {
        let source = scratch.url.appendingPathComponent("deep", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let payload = Data("at the bottom".utf8)
        let leaf = try makeDeepTree(
            under: source, depth: 7, name: String(repeating: "n", count: 200), contents: payload)
        #expect(leaf.utf8.count > Int(PATH_MAX))
        let destination = try makeDestination()

        let volume = InterposedArchiveVolume()
        #expect(
            extractFailure(
                try ClipboardArchive.archiveBytes(of: .directory(source)), into: destination,
                on: volume) == nil)
        #expect(readThroughDescriptors(leaf, under: destination) == payload)
        #expect(volume.mostOpenDirectories <= 2)
        #expect(volume.openDirectoryCount == 0)

        let removal = InterposedArchiveVolume()
        try StagedItemRemoval.remove(at: destination, on: removal)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(removal.mostOpenDirectories <= 2)
        #expect(removal.openDirectoryCount == 0)
    }

    /// APFS refuses the name; the failure names it as a display path, with
    /// the byte it could not store as U+FFFD.
    @Test("a name that is not UTF-8 fails the extract, naming it")
    func nameNotUTF8IsNamed() throws {
        let destination = try makeDestination()
        let archive = try rawArchive([
            .root(), .directory("dir"),
            RawArchiveEntry(
                type: .regularFile, path: Array("dir/caf".utf8) + [0xE9] + Array(".txt".utf8),
                mode: 0o644, data: Data("x".utf8)),
        ])

        #expect(
            extractFailure(archive, into: destination) as? ClipboardItemFailure
                == ClipboardItemFailure(itemPath: "dir/caf\u{FFFD}.txt", reason: .posix(EILSEQ)))
    }

    @Test("a file entry with no data lands as an empty file")
    func fileWithoutDataLandsEmpty() throws {
        let destination = try makeDestination()
        let archive = try rawArchive([
            .root(), RawArchiveEntry(type: .regularFile, path: Array("empty.txt".utf8), mode: 0o640),
        ])

        #expect(extractFailure(archive, into: destination) == nil)
        let path = destination.appendingPathComponent("empty.txt").path
        let status = try linkStatus(path)
        #expect(status.st_mode & S_IFMT == S_IFREG)
        #expect(status.st_mode & 0o7777 == 0o640)
        #expect(status.st_size == 0)
    }

    @Test("an entry left out lands none of the data it carries, and the entry after it lands whole")
    func leftOutEntryDataIsSkipped() throws {
        let destination = try makeDestination()
        let archive = try rawArchive([
            .root(),
            RawArchiveEntry(type: .fifo, path: Array("pipe".utf8), mode: 0o644, data: Data("left out".utf8)),
            .file("after.txt", "after"),
        ])

        #expect(extractFailure(archive, into: destination) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["after.txt"])
        #expect(try Data(contentsOf: destination.appendingPathComponent("after.txt")) == Data("after".utf8))
    }

    /// The blob after `DAT` spans more than one read, so it is read in
    /// pieces too.
    @Test("a file's data lands exactly with other blobs before and after it, and the next entry lands")
    func blobsAroundDataAreRead() throws {
        let destination = try makeDestination()
        var entry = RawArchiveEntry.file("file.txt", "the data")
        entry.blobsBefore = [(key: "XAT", data: Data("before".utf8))]
        entry.blobsAfter = [
            (key: "YAT", data: Data(repeating: 0x5A, count: ClipboardArchiveCodec.fileReadBlockSize + 17))
        ]
        let archive = try rawArchive([.root(), entry, .file("next.txt", "next")])

        #expect(extractFailure(archive, into: destination) == nil)
        #expect(try Data(contentsOf: destination.appendingPathComponent("file.txt")) == Data("the data".utf8))
        #expect(try Data(contentsOf: destination.appendingPathComponent("next.txt")) == Data("next".utf8))
    }

    @Test("a blob whose key is not letters and digits is refused as malformed")
    func blobKeyOutsideTheRuleIsMalformed() throws {
        let destination = try makeDestination()
        var entry = RawArchiveEntry.file("file.txt")
        entry.blobsBefore = [(key: "XAB", data: Data())]
        entry.editEncoding = { encoded in
            let key = Array("XAB".utf8)
            let starts = 0...(encoded.count - key.count)
            guard let start = starts.first(where: { Array(encoded[$0..<($0 + key.count)]) == key })
            else { return }
            encoded[start] = 0xE9
        }

        #expect(
            extractFailure(try rawArchive([.root(), entry]), into: destination)
                as? ClipboardArchiveMalformedEntry
                == ClipboardArchiveMalformedEntry(path: "file.txt", rule: .blobKey))
    }

    /// Two entries the volume takes for one name: the same bytes, or — where
    /// the volume ignores case — names that differ only in case.
    enum Collision: CaseIterable, Sendable {
        case samePath, caseOnly

        var names: (first: String, second: String) {
            switch self {
            case .samePath: ("dup.txt", "dup.txt")
            case .caseOnly: ("Readme", "README")
            }
        }
    }

    /// The two entries sit in one folder's batch, among others, so they are
    /// created side by side; in every other round of names that differ in
    /// case, the later entry takes the name first.
    @Test("two entries one name holds fail on the later, naming it, however they race", arguments: Collision.allCases)
    func collisionFailsOnTheLater(collision: Collision) throws {
        // On a case-sensitive volume the two names are two files, and there is
        // no collision to pin.
        if collision == .caseOnly, pathconf(scratch.url.path, _PC_CASE_SENSITIVE) != 0 { return }
        let (first, second) = collision.names
        // Longer than any other entry's data, so its write is told apart.
        let secondContents = "the second entry"
        let others = (0..<60).map { RawArchiveEntry.file("d/f\($0).txt", "\($0)") }
        let archive = try rawArchive(
            [.root(), .directory("d")] + others[..<30] + [.file("d/\(first)", "first")] + others[30...]
                + [.file("d/\(second)", secondContents), .directory("after")])

        for round in 0..<10 {
            let destination = scratch.url.appendingPathComponent("round-\(round)", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let laterWins = collision == .caseOnly && round % 2 == 1
            let secondWritten = DispatchSemaphore(value: 0)
            let volume = InterposedArchiveVolume { call throws(Errno) in
                guard laterWins else { return }
                switch call {
                case .createFile(let name) where name == Array(first.utf8):
                    _ = secondWritten.wait(timeout: .now() + testWaitBackstop)
                case .write(let byteCount) where byteCount == secondContents.utf8.count:
                    secondWritten.signal()
                default:
                    break
                }
            }
            #expect(
                extractFailure(archive, into: destination, on: volume) as? ClipboardItemFailure
                    == ClipboardItemFailure(itemPath: "d/\(second)", reason: .posix(EEXIST)), "round \(round)")
            let landed = try FileManager.default.contentsOfDirectory(
                atPath: destination.appendingPathComponent("d").path)
            #expect(landed.count == 61, "round \(round)")
            #expect(landed.filter { $0 == first || $0 == second }.count == 1, "round \(round)")
            if laterWins { #expect(landed.contains(second), "round \(round)") }
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["d"], "round \(round)")
        }
    }

    // MARK: - Entries no sender writes

    /// Each refused archive is extracted into a fresh destination beside an
    /// `outside` directory, and nothing may land anywhere but the destination.
    @Test("an entry outside the rules fails the extract, and nothing lands outside the destination")
    func malformedEntriesWriteNothingOutside() throws {
        let fm = FileManager.default
        let outside = scratch.url.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let cases: [(String, [RawArchiveEntry])] = [
            ("dot-dot", [.root(), .file("../escape.txt")]),
            ("dot-dot inside", [.root(), .directory("sub"), .file("sub/../../escape.txt")]),
            ("dot", [.root(), .directory("dot"), .file("dot/./b.txt")]),
            ("absolute", [.root(), .file(outside.appendingPathComponent("absolute.txt").path)]),
            ("empty component", [.root(), .directory("a"), .file("a//b.txt")]),
            ("trailing slash", [.root(), .directory("a/")]),
            (
                "NUL byte",
                [
                    .root(),
                    RawArchiveEntry(
                        type: .regularFile, path: Array("nul".utf8) + [0] + Array("x".utf8), mode: 0o644, data: Data()),
                ]
            ),
            ("missing parent", [.root(), .file("nowhere/x.txt")]),
            ("parent already left", [.root(), .directory("a"), .directory("b"), .file("a/late.txt")]),
            (
                "under a symlink",
                [
                    .root(),
                    RawArchiveEntry(type: .link, path: Array("l".utf8), link: Array(outside.path.utf8), mode: 0o755),
                    .file("l/x.txt"),
                ]
            ),
            (
                "under a relative symlink",
                [
                    .root(),
                    RawArchiveEntry(type: .link, path: Array("r".utf8), link: Array("../outside".utf8), mode: 0o755),
                    .file("r/y.txt"),
                ]
            ),
            ("root not first", [.file("first.txt"), .root()]),
            ("root not a directory", [RawArchiveEntry(type: .regularFile, path: [], mode: 0o644, data: Data())]),
            ("link without a target", [.root(), RawArchiveEntry(type: .link, path: Array("l".utf8), mode: 0o755)]),
        ]
        for (index, (label, entries)) in cases.enumerated() {
            let holder = scratch.url.appendingPathComponent("case-\(index)", isDirectory: true)
            let destination = holder.appendingPathComponent("out", isDirectory: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)

            // The decoder refuses some of these itself; either refusal fails
            // the extract.
            let failure = extractFailure(try rawArchive(entries), into: destination)
            #expect(failure != nil, "\(label)")
            #expect(!(failure is ClipboardItemFailure), "\(label): \(String(describing: failure))")
            #expect(try fm.contentsOfDirectory(atPath: holder.path) == ["out"], "\(label)")
            #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty, "\(label)")
            #expect(!fm.fileExists(atPath: scratch.url.appendingPathComponent("escape.txt").path), "\(label)")
        }
    }

    @Test("an entry whose parent no earlier entry created is refused as malformed")
    func missingParentIsMalformed() throws {
        let destination = try makeDestination()
        #expect(
            extractFailure(try rawArchive([.root(), .file("nowhere/x.txt")]), into: destination)
                as? ClipboardArchiveMalformedEntry
                == ClipboardArchiveMalformedEntry(path: "nowhere/x.txt", rule: .parent))
    }

    // MARK: - Attributes

    @Test("set-id and sticky bits land as written, setgid with the group it names")
    func specialModeBitsLand() throws {
        let destination = try makeDestination()
        var setgid = RawArchiveEntry.file("setgid", mode: 0o2755)
        setgid.gid = UInt64(getegid())
        let archive = try rawArchive([
            .root(), .file("setuid", mode: 0o4755), setgid,
            .file("sticky", mode: 0o1644), .directory("shared", mode: 0o1777),
        ])
        #expect(extractFailure(archive, into: destination) == nil)
        for (name, mode) in [("setuid", 0o4755), ("setgid", 0o2755), ("sticky", 0o1644), ("shared", 0o1777)] {
            let status = try linkStatus(destination.appendingPathComponent(name).path)
            #expect(Int(status.st_mode & 0o7777) == mode, "\(name)")
        }
    }

    @Test("a 0555 and a 0000 directory land with their contents and then their mode")
    func readOnlyDirectoriesLandWhole() throws {
        let destination = try makeDestination()
        let archive = try rawArchive([
            .root(),
            timed(.directory("locked", mode: 0o555)), .file("locked/a.txt", "a"),
            .directory("locked/inner"), .file("locked/inner/b.txt", "b"),
            timed(.directory("sealed", mode: 0)), .file("sealed/c.txt", "c"),
        ])
        #expect(extractFailure(archive, into: destination) == nil)

        let locked = destination.appendingPathComponent("locked").path
        let sealed = destination.appendingPathComponent("sealed").path
        #expect(try linkStatus(locked).st_mode & 0o7777 == 0o555)
        #expect(try linkStatus(sealed).st_mode & 0o7777 == 0)
        try expectTimes(locked)
        try expectTimes(sealed)
        #expect(readThroughDescriptors("locked/inner/b.txt", under: destination) == Data("b".utf8))
        #expect(chmod(sealed, 0o700) == 0)
        #expect(readThroughDescriptors("sealed/c.txt", under: destination) == Data("c".utf8))
    }

    @Test("the four settable flags land, and immutable and append arrive cleared")
    func settableFlagsLandAndLocksDoNot() throws {
        let destination = try makeDestination()
        let settable = UInt64(UF_NODUMP | UF_OPAQUE | UF_TRACKED | UF_HIDDEN)
        let locks = UInt64(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
        var file = RawArchiveEntry.file("flagged.txt", "f")
        file.flags = settable | locks
        var directory = RawArchiveEntry.directory("flagged")
        directory.flags = settable | locks
        var link = RawArchiveEntry(type: .link, path: Array("flagged-link".utf8), link: Array("x".utf8), mode: 0o755)
        link.flags = settable | locks

        #expect(extractFailure(try rawArchive([.root(), file, directory, link]), into: destination) == nil)
        for name in ["flagged.txt", "flagged", "flagged-link"] {
            let flags = UInt64(try linkStatus(destination.appendingPathComponent(name).path).st_flags)
            #expect(flags & settable == settable, "\(name)")
            #expect(flags & locks == 0, "\(name)")
        }
        // The point of clearing them: what landed can be removed.
        try StagedItemRemoval.remove(at: destination)
    }

    @Test("flags the receiver cannot set cost an entry none of its other attributes")
    func unsettableFlagsCostNothing() throws {
        let destination = try makeDestination()
        let unsettable = UInt64(SF_ARCHIVED | SF_RESTRICTED | SF_NOUNLINK | UF_DATAVAULT | UF_COMPRESSED)
        var file = timed(.file("file.txt", "f", mode: 0o640))
        file.flags = unsettable | UInt64(UF_HIDDEN)
        var directory = timed(.directory("dir", mode: 0o750))
        directory.flags = unsettable
        var link = timed(RawArchiveEntry(type: .link, path: Array("link".utf8), link: Array("x".utf8), mode: 0o700))
        link.flags = unsettable

        #expect(extractFailure(try rawArchive([.root(), file, directory, link]), into: destination) == nil)
        for (name, mode) in [("file.txt", 0o640), ("dir", 0o750), ("link", 0o700)] {
            let path = destination.appendingPathComponent(name).path
            let status = try linkStatus(path)
            #expect(Int(status.st_mode & 0o7777) == mode, "\(name)")
            #expect(UInt64(status.st_flags) & unsettable == 0, "\(name)")
            try expectTimes(path)
        }
        #expect(try linkStatus(destination.appendingPathComponent("file.txt").path).st_flags & UInt32(UF_HIDDEN) != 0)
    }

    @Test("a group the receiver is in is applied, and one it is not in leaves the entry as created")
    func groupsApplyWhereTheyCan() throws {
        let destination = try makeDestination()
        let inherited = try linkStatus(destination.path).st_gid
        let members = Self.memberGroups()
        // Another group than the one an entry inherits, where there is one, so
        // the applied group is told apart from the inherited one.
        let member = members.first { $0 != inherited } ?? inherited
        let foreign = try Self.foreignGroup()
        var joined = timed(.file("joined.txt", mode: 0o640))
        joined.gid = UInt64(member)
        var refused = timed(.file("refused.txt", mode: 0o640))
        refused.gid = UInt64(foreign)
        var refusedLink = timed(
            RawArchiveEntry(type: .link, path: Array("refused-link".utf8), link: Array("x".utf8), mode: 0o755))
        refusedLink.gid = UInt64(foreign)
        var owned = timed(.file("owned-by-root.txt", mode: 0o4750))
        owned.uid = 0

        #expect(
            extractFailure(try rawArchive([.root(), joined, refused, refusedLink, owned]), into: destination)
                == nil)
        #expect(try linkStatus(destination.appendingPathComponent("joined.txt").path).st_gid == member)
        for name in ["refused.txt", "refused-link"] {
            let path = destination.appendingPathComponent(name).path
            #expect(try linkStatus(path).st_gid == inherited, "\(name)")
            try expectTimes(path)
        }
        let ownedStatus = try linkStatus(destination.appendingPathComponent("owned-by-root.txt").path)
        #expect(ownedStatus.st_uid == geteuid())
        #expect(ownedStatus.st_mode & 0o7777 == 0o4750)
    }

    /// How an entry's group goes unapplied.
    enum UnappliedGroup: CaseIterable, Sendable {
        /// One the receiver is not in, which the kernel refuses.
        case foreign
        /// A value no group can have.
        case invalid
        /// One the target refuses as an attribute it cannot hold.
        case refusedByTarget
        /// None at all.
        case absent
    }

    @Test(
        "setgid with a group that was not applied is dropped, and the other mode bits and times land",
        arguments: UnappliedGroup.allCases)
    func setgidWithoutItsGroupIsDropped(group: UnappliedGroup) throws {
        let destination = try makeDestination()
        let inherited = try linkStatus(destination.path).st_gid
        var file = timed(.file("setgid.txt", mode: 0o2750))
        var directory = timed(.directory("setgid-dir", mode: 0o2750))
        let gid: UInt64? =
            switch group {
            case .foreign: UInt64(try Self.foreignGroup())
            case .invalid: UInt64(UInt32.max) + 1
            case .refusedByTarget: UInt64(getegid())
            case .absent: nil
            }
        file.gid = gid
        directory.gid = gid
        let volume = InterposedArchiveVolume { call throws(Errno) in
            if group == .refusedByTarget, case .setGroup = call { throw .invalidArgument }
        }

        #expect(extractFailure(try rawArchive([.root(), file, directory]), into: destination, on: volume) == nil)
        for name in ["setgid.txt", "setgid-dir"] {
            let path = destination.appendingPathComponent(name).path
            let status = try linkStatus(path)
            #expect(status.st_mode & 0o7777 == 0o0750, "\(name)")
            #expect(status.st_gid == inherited, "\(name)")
            try expectTimes(path)
        }
    }

    /// The entries ``unheldAttributeIsLeftOut(kind:errno:)`` checks, the
    /// root as an empty name, and the mode each asks for.
    private static let refusalEntries: [(name: String, mode: mode_t)] = [
        ("file.txt", 0o640), ("dir", 0o750), ("link", 0o700), ("", 0o750),
    ]

    /// exFAT and FAT refuse every flag but `UF_HIDDEN` with `EINVAL`.
    @Test(
        "an attribute the target cannot hold is left out, and every other attribute lands",
        arguments: ArchiveAttributeKind.allCases,
        [Errno.invalidArgument, .notSupported, .notSupportedOnSocket, .notPermitted])
    func unheldAttributeIsLeftOut(kind: ArchiveAttributeKind, errno: Errno) throws {
        let destination = try makeDestination()
        var root = timed(.root(mode: 0o750))
        var file = timed(.file("file.txt", "f", mode: 0o640))
        var directory = timed(.directory("dir", mode: 0o750))
        var link = timed(RawArchiveEntry(type: .link, path: Array("link".utf8), link: Array("x".utf8), mode: 0o700))
        root.flags = UInt64(UF_HIDDEN)
        file.flags = UInt64(UF_HIDDEN)
        directory.flags = UInt64(UF_HIDDEN)
        link.flags = UInt64(UF_HIDDEN)

        #expect(
            extractFailure(
                try rawArchive([root, file, directory, link]), into: destination,
                on: InterposedArchiveVolume.refusing(kind, with: errno)) == nil)
        for (name, mode) in Self.refusalEntries {
            let path = name.isEmpty ? destination.path : destination.appendingPathComponent(name).path
            let status = try linkStatus(path)
            #expect((status.st_mode & 0o7777 == mode) == (kind != .mode), "mode of \(name)")
            #expect((status.st_flags & UInt32(UF_HIDDEN) != 0) == (kind != .flags), "flags of \(name)")
            #expect(
                sameInstant(status.st_mtimespec, Self.modification) == (kind != .modification), "mtime of \(name)")
            #expect(
                sameInstant(status.st_birthtimespec, Self.creation) == (kind != .creation), "birth time of \(name)")
        }
    }

    @Test("an attribute the target refuses for another reason fails the extract, naming the entry")
    func refusedAttributeIsAFailure() throws {
        let destination = try makeDestination()
        let archive = try rawArchive([.root(), .directory("d"), .file("d/file.txt", "f", mode: 0o640)])

        #expect(
            extractFailure(archive, into: destination, on: InterposedArchiveVolume.refusing(.mode, with: .ioError))
                as? ClipboardItemFailure
                == ClipboardItemFailure(itemPath: "d/file.txt", reason: .posix(EIO)))
    }

    @Test("the root entry's attributes land on the destination itself, after everything in it")
    func rootAttributesLandOnTheDestination() throws {
        let destination = try makeDestination()
        var root = timed(RawArchiveEntry.root(mode: 0o750))
        root.flags = UInt64(UF_HIDDEN)

        #expect(extractFailure(try rawArchive([root, .file("inside.txt", "x")]), into: destination) == nil)
        let status = try linkStatus(destination.path)
        #expect(status.st_mode & 0o7777 == 0o750)
        #expect(status.st_flags & UInt32(UF_HIDDEN) != 0)
        try expectTimes(destination.path)
    }

    @Test("times land on files, on directories after their children, and on symlinks")
    func timesLandOnEveryKind() throws {
        let destination = try makeDestination()
        let archive = try rawArchive([
            .root(),
            timed(.directory("dir")), .directory("dir/sub"), .file("dir/sub/late.txt", "late"),
            timed(.file("file.txt", "f")),
            timed(RawArchiveEntry(type: .link, path: Array("link".utf8), link: Array("file.txt".utf8), mode: 0o755)),
        ])
        #expect(extractFailure(archive, into: destination) == nil)
        for name in ["dir", "file.txt", "link"] {
            try expectTimes(destination.appendingPathComponent(name).path)
        }
        // The link's own times, not its target's.
        #expect(try linkStatus(destination.appendingPathComponent("link").path).st_mode & S_IFMT == S_IFLNK)
    }

    // MARK: - Holes

    /// A file's data as runs of hole-sized blocks, each all zeros or not, then
    /// a tail of data shorter than a block.
    enum SparseLayout: CaseIterable, Sendable {
        case zerosBetweenData, trailingZeros, leadingZeros, allZeros

        /// The runs, as whether each is zeros and how many blocks it holds,
        /// and the tail's byte count.
        func shape(scale: Int) -> (runs: [(zeros: Bool, blocks: Int)], tail: Int) {
            switch self {
            case .zerosBetweenData: ([(false, 3 * scale), (true, 5 * scale), (false, 2 * scale)], 100)
            case .trailingZeros: ([(false, 2 * scale), (true, 7 * scale)], 0)
            case .leadingZeros: ([(true, 4 * scale), (false, 1 * scale)], 1)
            case .allZeros: ([(true, 6 * scale)], 0)
            }
        }
    }

    /// The bytes `layout` describes in blocks of `holeSize`, and how many of
    /// them are data a hole cannot replace, whole blocks included.
    private static func sparseContents(
        _ layout: SparseLayout, scale: Int, holeSize: Int
    ) -> (contents: Data, allocated: Int) {
        let (runs, tail) = layout.shape(scale: scale)
        var contents = Data()
        var allocated = 0
        func append(random count: Int) {
            var bytes = [UInt8](repeating: 0, count: count)
            arc4random_buf(&bytes, count)
            // A data block of all zeros would be a hole too.
            for block in stride(from: 0, to: count, by: holeSize) { bytes[block] |= 1 }
            contents.append(contentsOf: bytes)
        }
        for (zeros, blocks) in runs {
            if zeros {
                contents.append(Data(count: blocks * holeSize))
            } else {
                append(random: blocks * holeSize)
                allocated += blocks * holeSize
            }
        }
        if tail > 0 {
            append(random: tail)
            allocated += holeSize
        }
        return (contents, allocated)
    }

    /// The hole size of the volume the scratch directory is on, or `nil`
    /// when it makes none.
    private func scratchHoleSize() throws -> Int? {
        let descriptor = open(scratch.url.path, O_RDONLY)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        return ClipboardArchiveLocalVolume().holeSize(of: descriptor)
    }

    /// A small file is written in its folder's batch, a large one — whose
    /// data also arrives in more than one piece — on its own.
    @Test(
        "whole blocks of zeros land as holes, and the file reads back byte for byte",
        arguments: SparseLayout.allCases, [1, ClipboardArchiveCodec.fileReadBlockSize / 4096])
    func zeroBlocksLandAsHoles(layout: SparseLayout, scale: Int) throws {
        guard let holeSize = try scratchHoleSize() else { return }
        let destination = try makeDestination()
        let (contents, allocated) = Self.sparseContents(layout, scale: scale, holeSize: holeSize)
        var entry = RawArchiveEntry.file("sparse.bin")
        entry.data = contents

        #expect(extractFailure(try rawArchive([.root(), entry]), into: destination) == nil)
        let path = destination.appendingPathComponent("sparse.bin").path
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == contents)
        let status = try linkStatus(path)
        #expect(Int(status.st_size) == contents.count)
        #expect(Int(status.st_blocks) * 512 == allocated)
    }

    @Test(
        "on a volume that refuses to punch the holes it reports, the file reads back byte for byte",
        arguments: SparseLayout.allCases, [1, ClipboardArchiveCodec.fileReadBlockSize / 4096])
    func refusedPunchLeavesTheFileWhole(layout: SparseLayout, scale: Int) throws {
        guard let holeSize = try scratchHoleSize() else { return }
        let destination = try makeDestination()
        let (contents, _) = Self.sparseContents(layout, scale: scale, holeSize: holeSize)
        var entry = RawArchiveEntry.file("sparse.bin")
        entry.data = contents
        let volume = InterposedArchiveVolume { call throws(Errno) in
            if case .punchHole = call { throw .notSupported }
        }

        #expect(extractFailure(try rawArchive([.root(), entry]), into: destination, on: volume) == nil)
        let path = destination.appendingPathComponent("sparse.bin").path
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == contents)
        #expect(Int(try linkStatus(path).st_size) == contents.count)
    }

    @Test(
        "a file whose trailing zeros cannot be sized fails the extract, naming the file",
        arguments: [1, ClipboardArchiveCodec.fileReadBlockSize / 4096])
    func failedTruncateIsAFailure(scale: Int) throws {
        guard let holeSize = try scratchHoleSize() else { return }
        let destination = try makeDestination()
        let (contents, _) = Self.sparseContents(.trailingZeros, scale: scale, holeSize: holeSize)
        var entry = RawArchiveEntry.file("sparse.bin")
        entry.data = contents
        let volume = InterposedArchiveVolume { call throws(Errno) in
            if case .setSize = call { throw .ioError }
        }

        #expect(
            extractFailure(try rawArchive([.root(), entry]), into: destination, on: volume) as? ClipboardItemFailure
                == ClipboardItemFailure(itemPath: "sparse.bin", reason: .posix(EIO)))
    }

    @Test("on a volume that reports no holes, a file's zeros are written as data")
    func zerosAreWrittenWhereNoHoles() throws {
        guard let holeSize = try scratchHoleSize() else { return }
        let destination = try makeDestination()
        let (contents, _) = Self.sparseContents(.zerosBetweenData, scale: 8, holeSize: holeSize)
        var entry = RawArchiveEntry.file("sparse.bin")
        entry.data = contents
        let punched = Locked(false)
        let volume = InterposedArchiveVolume(reportsHoles: false) { call throws(Errno) in
            if case .punchHole = call { punched.withLock { $0 = true } }
        }

        #expect(extractFailure(try rawArchive([.root(), entry]), into: destination, on: volume) == nil)
        let path = destination.appendingPathComponent("sparse.bin").path
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == contents)
        #expect(Int(try linkStatus(path).st_blocks) * 512 == (contents.count + holeSize - 1) / holeSize * holeSize)
        #expect(!punched.withLock { $0 })
    }

    // MARK: - Attribute calls

    @Test(
        "an entry's attributes land in one call, and one each only after the target refuses it",
        arguments: [nil, ArchiveAttributeKind.flags])
    func attributesLandInOneCall(refused: ArchiveAttributeKind?) throws {
        let destination = try makeDestination()
        var entries = [
            timed(.root(mode: 0o750)), timed(.file("file.txt", "f", mode: 0o640)),
            timed(.directory("dir", mode: 0o750)),
            timed(RawArchiveEntry(type: .link, path: Array("link".utf8), link: Array("x".utf8), mode: 0o700)),
        ]
        for index in entries.indices { entries[index].flags = UInt64(UF_HIDDEN) }
        let calls = Locked<[Set<ArchiveAttributeKind>]>([])
        let volume = InterposedArchiveVolume { call throws(Errno) in
            guard case .setAttributes(let attributes, _) = call else { return }
            let kinds = ArchiveAttributeKind.kinds(of: attributes)
            calls.withLock { $0.append(kinds) }
            if let refused, kinds.contains(refused) { throw .invalidArgument }
        }

        #expect(extractFailure(try rawArchive(entries), into: destination, on: volume) == nil)
        let made = calls.withLock { $0 }
        let every = Set(ArchiveAttributeKind.allCases)
        #expect(made.filter { $0 == every }.count == entries.count)
        for kind in ArchiveAttributeKind.allCases {
            #expect(made.filter { $0 == [kind] }.count == (refused == nil ? 0 : entries.count), "\(kind)")
        }
        #expect(made.count == entries.count * (refused == nil ? 1 : 1 + every.count))
    }

    // MARK: - Batches

    /// Folders of `perFolder` entries each — every seventh a symlink, the
    /// files' sizes spanning the batch's largest — each entry with its own
    /// mode, times and flags, every folder read-only so an entry created
    /// after its folder's attributes fails.
    private static func manyEntries(folders: Int, perFolder: Int) -> [RawArchiveEntry] {
        let sizes = [0, 1, 100, 4096, 5000, 70_000, 300_000]
        var entries = [RawArchiveEntry.root()]
        var index = 0
        func stamped(_ entry: RawArchiveEntry) -> RawArchiveEntry {
            var entry = entry
            index += 1
            entry.mode = UInt64(0o600 | index % 64)
            entry.flags = index % 2 == 0 ? UInt64(UF_HIDDEN) : 0
            entry.gid = UInt64(getegid())
            entry.creation = timespec(tv_sec: 981_173_106 + index, tv_nsec: index)
            entry.modification = timespec(tv_sec: 1_013_000_000 + index, tv_nsec: 2 * index)
            return entry
        }
        for folder in 0..<folders {
            var directory = stamped(.directory("d\(folder)"))
            directory.mode = 0o555
            entries.append(directory)
            for item in 0..<perFolder {
                let path = "d\(folder)/e\(item)"
                if item % 7 == 3 {
                    entries.append(
                        stamped(RawArchiveEntry(type: .link, path: Array(path.utf8), link: Array("t\(item)".utf8))))
                } else {
                    var file = stamped(.file(path))
                    let size = sizes[item % sizes.count]
                    var bytes = [UInt8](repeating: 0, count: size)
                    arc4random_buf(&bytes, size)
                    file.data = Data(bytes)
                    entries.append(file)
                }
            }
        }
        return entries
    }

    @Test("a tree of many small files and symlinks lands with every entry's contents and attributes")
    func manySmallEntriesLandWhole() throws {
        let destination = try makeDestination()
        let entries = Self.manyEntries(folders: 3, perFolder: 600)

        #expect(extractFailure(try rawArchive(entries), into: destination) == nil)
        for entry in entries.dropFirst() {
            let name = String(decoding: entry.path, as: UTF8.self)
            let path = destination.appendingPathComponent(name).path
            let status = try linkStatus(path)
            #expect(UInt64(status.st_mode & 0o7777) == entry.mode, "mode of \(name)")
            #expect(UInt64(status.st_flags) == entry.flags, "flags of \(name)")
            #expect(status.st_gid == getegid(), "group of \(name)")
            #expect(sameInstant(status.st_mtimespec, try #require(entry.modification)), "mtime of \(name)")
            #expect(sameInstant(status.st_birthtimespec, try #require(entry.creation)), "birth time of \(name)")
            switch entry.type {
            case .regularFile?:
                #expect(status.st_mode & S_IFMT == S_IFREG, "\(name)")
                #expect(FileManager.default.contents(atPath: path) == entry.data ?? Data(), "contents of \(name)")
            case .link?:
                #expect(
                    try FileManager.default.destinationOfSymbolicLink(atPath: path)
                        == String(decoding: try #require(entry.link), as: UTF8.self), "\(name)")
            default:
                #expect(status.st_mode & S_IFMT == S_IFDIR, "\(name)")
            }
        }
    }

    @Test("a batch holds the folder it lands in and one file per worker open, closing all of them")
    func batchDescriptorsStayBounded() throws {
        let destination = try makeDestination()
        let volume = InterposedArchiveVolume()

        #expect(
            extractFailure(
                try rawArchive(Self.manyEntries(folders: 2, perFolder: 1000)), into: destination, on: volume)
                == nil)
        #expect(volume.mostOpenDirectories <= 2)
        #expect(volume.mostOpenFiles <= ProcessInfo.processInfo.activeProcessorCount)
        #expect(volume.openDirectoryCount == 0)
        #expect(volume.openFileCount == 0)
    }

    @Test("of the entries in a batch that fail, the failure is the first in archive order's, and nothing after lands")
    func batchFailureIsTheFirstInArchiveOrder() throws {
        let files = (0..<200).map { RawArchiveEntry.file("d/f\($0)", "\($0)") }
        let archive = try rawArchive([.root(), .directory("d")] + files + [.directory("after")])
        let failing: Set<[UInt8]> = [Array("f150".utf8), Array("f40".utf8), Array("f41".utf8)]
        let volume = InterposedArchiveVolume { call throws(Errno) in
            if case .createFile(let name) = call, failing.contains(name) { throw .ioError }
        }

        for round in 0..<10 {
            let destination = scratch.url.appendingPathComponent("round-\(round)", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            #expect(
                extractFailure(archive, into: destination, on: volume) as? ClipboardItemFailure
                    == ClipboardItemFailure(itemPath: "d/f40", reason: .posix(EIO)), "round \(round)")
            #expect(
                !FileManager.default.fileExists(atPath: destination.appendingPathComponent("after").path),
                "round \(round)")
        }
    }

    /// The guard runs in the decode, on the extract's thread, so no batch is
    /// being created while it refuses.
    @Test("an output guard refusing while a batch fills stops the extract, and no entry is created after it")
    func refusalMidBatchStopsTheExtract() throws {
        let destination = try makeDestination()
        let count = 2000
        let files = (0..<count).map { index -> RawArchiveEntry in
            var file = RawArchiveEntry.file("d/f\(index)")
            var bytes = [UInt8](repeating: 0, count: 2048)
            arc4random_buf(&bytes, bytes.count)
            file.data = Data(bytes)
            return file
        }
        let archive = try rawArchive([.root(), .directory("d")] + files)
        let refused = Locked(false)
        let createdAfter = Locked(0)
        let volume = InterposedArchiveVolume { call throws(Errno) in
            if case .createFile = call, refused.withLock({ $0 }) { createdAfter.withLock { $0 += 1 } }
        }

        let failure = ClipboardArchiveCodec.extract(
            from: ClipboardArchiveDataSource(bytes: archive), into: destination, on: volume,
            counted: Locked(0), pacingBytes: 64 * 1024,
            onOutputAdvanced: { total in
                guard total >= 1024 * 1024 else { return }
                refused.withLock { $0 = true }
                throw ClipboardArchiveStreamError.outputRefused(.overAdvertisedSize)
            })

        #expect(failure != nil)
        #expect(refused.withLock { $0 })
        #expect(createdAfter.withLock { $0 } == 0)
        let landed = try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent("d").path)
        #expect(landed.count < count)
    }

    // MARK: - Writes

    @Test("a write the volume refuses fails the extract, naming the file and the errno")
    func refusedWriteIsNamed() throws {
        let destination = try makeDestination()
        let archive = try rawArchive([.root(), .directory("d"), .file("d/full.bin", "payload")])

        #expect(
            extractFailure(archive, into: destination, on: InterposedArchiveVolume(failingWritesWith: .noSpace))
                as? ClipboardItemFailure
                == ClipboardItemFailure(itemPath: "d/full.bin", reason: .posix(ENOSPC)))
    }
}
