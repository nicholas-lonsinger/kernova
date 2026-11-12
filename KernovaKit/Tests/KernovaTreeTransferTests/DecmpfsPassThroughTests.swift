#if canImport(Darwin)
import Darwin
import Foundation
import KernovaContainer
import KernovaDigest
import KernovaFileTree
import KernovaPortableTestSupport
import KernovaWire
import Testing

@testable import KernovaTreeTransfer

/// The types this kernel's row lists, which pass-through lands compressed.
private let runningTypes = DecmpfsMatrix.types(for: DecmpfsMatrix.runningKernel)

/// Files carried in their decmpfs-compressed form, and the platform behavior that form rests on.
@Suite("decmpfs pass-through")
struct DecmpfsPassThroughTests {
    let fileSystem = POSIXTreeFileSystem()

    /// Writes `events`, returning the first failure.
    private static func failure(writing events: [TreeEvent], to writer: TreeWriter<POSIXTreeFileSystem>)
        -> TreeWriteFailure?
    {
        do {
            for event in events { try writer.write(event) }
            return nil
        } catch {
            return error
        }
    }

    /// The types whose compressed bytes the attribute holds, which takes at most 3,802 bytes.
    static let attributeTypes: Set<UInt32> = [3, 7, 9, 11, 13, 15]

    // MARK: - The kernel matrix

    @Test("every type the running kernel's row lists, built from plain data and created compressed, reads back")
    func kernelMatrix() throws {
        let scratch = try PortableScratchDirectory(prefix: "decmpfs-matrix")
        let directory = try fileSystem.openDirectory(Array(scratch.path.utf8), in: AT_FDCWD)
        defer { fileSystem.close(directory) }
        for type in runningTypes.sorted() {
            // LZVN has no public constant, so the type-8 file is `/bin/ls` as it is stored.
            let sample =
                type == 8
                ? try CompressedSample.read("/bin/ls", on: fileSystem)
                : CompressedSample.built(
                    type: type, plain: sampleText(Self.attributeTypes.contains(type) ? 3_000 : 1_000_000))
            guard let sample else {
                Issue.record("no sample builds type \(type), which the matrix lists")
                continue
            }
            #expect(sample.type == type)
            let name = Array("type-\(type)".utf8)
            let file = try CompressedFile(
                creating: name, in: directory, attribute: sample.attribute, logicalSize: sample.logicalSize,
                resourceForkLength: UInt64(sample.resourceFork.count), extendedAttributes: [], on: fileSystem)
            try sample.resourceFork.withUnsafeBytes { fork in
                for start in stride(from: 0, to: fork.count, by: ContainerEncoder.chunkByteCount) {
                    let end = min(start + ContainerEncoder.chunkByteCount, fork.count)
                    try file.appendResourceFork(UnsafeRawBufferPointer(rebasing: fork[start..<end]))
                }
            }
            let status = try file.finish(TreeEntryAttributes(permissions: 0o644))
            #expect(status.isCompressed, "type \(type) is compressed")
            let path = scratch.path + "/type-\(type)"
            #expect(try contents(of: path) == sample.plain, "type \(type) reads back")
        }
        if DecmpfsMatrix.runningKernel == DecmpfsMatrix.Kernel(major: 27, minor: 2) {
            #expect(runningTypes == [3, 4, 7, 8, 9, 11, 12, 13, 14, 15, 16])
        }
    }

    @Test("a kernel without a row accepts no type, and a release that is not a version names no kernel")
    func kernelsWithoutRows() throws {
        #expect(DecmpfsMatrix.types(for: DecmpfsMatrix.Kernel(major: 26, minor: 0)).isEmpty)
        #expect(DecmpfsMatrix.types(for: nil).isEmpty)
        #expect(DecmpfsMatrix.Kernel(release: "27.2.0") == DecmpfsMatrix.Kernel(major: 27, minor: 2))
        #expect(DecmpfsMatrix.Kernel(release: "Darwin") == nil)
        let scratch = try PortableScratchDirectory(prefix: "decmpfs-kernel")
        let directory = try fileSystem.openDirectory(Array(scratch.path.utf8), in: AT_FDCWD)
        defer { fileSystem.close(directory) }
        #expect(try fileSystem.volumeStoresCompressedFiles(directory))
        #expect(
            try DecmpfsMatrix.acceptedTypes(
                landingIn: directory, on: fileSystem, kernel: DecmpfsMatrix.Kernel(major: 26, minor: 0)
            ).isEmpty)
        #expect(try DecmpfsMatrix.acceptedTypes(landingIn: directory, on: fileSystem) == runningTypes)
    }

    // MARK: - Round trips

    /// A source folder of compressed files — `/bin/ls` (type 8, a resource fork), `/usr/bin/pp` (type 9, in
    /// the attribute), a type-4 file, and one whose resource fork is larger than a folder batch takes, so it
    /// is written as it arrives — copied with `copyfile`, which keeps them compressed, beside a plain file
    /// with a resource fork and a folder's custom icon.
    private static func buildSource(on bench: FidelityBench) throws -> [[[UInt8]]] {
        let item = bytes("item")
        try bench.makeDirectory([item])
        var compressed: [(String, String)] = [("/bin/ls", "ls"), ("/usr/bin/pp", "pp")]
        for (name, size) in [("type4", 400_000), ("type4-large", 2_000_000)] {
            let type4 = try #require(CompressedSample.built(type: 4, plain: sampleText(size, seed: UInt64(size))))
            let staged = bench.scratch.path + "/" + name
            close(try createCompressedDirectly(staged, type4))
            compressed.append((staged, name))
        }
        for (source, name) in compressed {
            let copied = copyfile(source, bench.sourcePath + "/item/" + name, nil, copyfile_flags_t(COPYFILE_ALL))
            try #require(copied == 0, "copyfile \(source)")
        }
        try bench.makeFile([item, bytes("forked")], Data("data".utf8))
        try bench.setExtendedAttribute(
            [item, bytes("forked")], "com.apple.ResourceFork", Array(randomBytes(100 << 10, seed: 21)))
        try bench.makeDirectory([item, bytes("custom-icon")])
        try bench.makeFile([item, bytes("custom-icon"), bytes("Icon\r")], Data())
        try bench.setExtendedAttribute(
            [item, bytes("custom-icon"), bytes("Icon\r")], "com.apple.ResourceFork",
            Array(randomBytes(150 << 10, seed: 22)))
        return compressed.map { (_, name) -> [[UInt8]] in [item, bytes(name)] }
    }

    @Test(
        "with pass-through on, /bin/ls, /usr/bin/pp and a type-4 file land compressed at their source's st_blocks",
        .enabled(if: runningTypes.isSuperset(of: [4, 8, 9])))
    func passThroughRoundTrip() throws {
        let bench = try FidelityBench()
        let compressed = try Self.buildSource(on: bench)
        let destination = try fileSystem.openDirectory(bytes(bench.destinationPath), in: AT_FDCWD)
        let types = try DecmpfsMatrix.acceptedTypes(landingIn: destination, on: fileSystem)
        fileSystem.close(destination)
        let acceptance = ContainerAcceptance(
            storage: .folder, byteCeiling: 1 << 30, decmpfsTypes: types, acceptsLZ4: true)

        let events = try bench.events(bytes("item"), accepting: acceptance)
        let decmpfsHeaders = events.compactMap { event -> EntryHeader? in
            guard case .beginFile(let header) = event, case .decmpfs = header.storage else { return nil }
            return header
        }
        #expect(Set(decmpfsHeaders.map { Array($0.name) }) == Set(compressed.map { $0[1] }))

        #expect(try bench.roundTrip(bytes("item"), accepting: acceptance, policy: .never) == bytes("item"))
        let source = try bench.facts(of: bytes("item"), in: bench.sourcePath)
        let landed = try bench.facts(of: bytes("item"), in: bench.destinationPath)
        #expect(Set(landed.keys) == Set(source.keys))
        for components in compressed {
            let read = try #require(source[components])
            let wrote = try #require(landed[components])
            let name = String(decoding: components[1], as: UTF8.self)
            try #require(read.flags & FileStatus.compressedFlag != 0, "\(name) is compressed in the source")
            #expect(wrote.flags & FileStatus.compressedFlag != 0, "\(name) landed compressed")
            #expect(wrote.blocks == read.blocks, "st_blocks of \(name)")
            #expect(wrote.size == read.size, "size of \(name)")
            #expect(wrote.digest == read.digest, "SHA-256 of \(name)")
            #expect(wrote.modificationTime == read.modificationTime, "mtime of \(name)")
            #expect(wrote.permissions == read.permissions, "mode of \(name)")
        }
        for (components, read) in source where !compressed.contains(components) {
            #expect(landed[components]?.digest == read.digest)
            #expect(landed[components]?.resourceFork == read.resourceFork)
            #expect(landed[components]?.blocks == read.blocks)
        }
    }

    @Test("with pass-through off, compressed files land as their plain bytes, and their storage stays home")
    func passThroughOff() throws {
        let bench = try FidelityBench()
        let compressed = try Self.buildSource(on: bench)
        let acceptance = ContainerAcceptance(
            storage: .folder, byteCeiling: 1 << 30, decmpfsTypes: [], acceptsLZ4: false)
        let events = try bench.events(bytes("item"), accepting: acceptance)
        #expect(
            !events.contains {
                if case .beginFile(let header) = $0, case .decmpfs = header.storage { true } else { false }
            })
        #expect(try bench.roundTrip(bytes("item"), accepting: acceptance, policy: .never) == bytes("item"))
        let source = try bench.facts(of: bytes("item"), in: bench.sourcePath)
        let landed = try bench.facts(of: bytes("item"), in: bench.destinationPath)
        for components in compressed {
            let wrote = try #require(landed[components])
            #expect(wrote.flags & FileStatus.compressedFlag == 0)
            #expect(wrote.digest == source[components]?.digest)
            #expect(wrote.resourceFork == nil, "a compressed file shows no resource fork")
        }
    }

    // MARK: - Resource forks

    @Test(
        "a resource fork above a header record's 64 KiB, on a folder's Icon\\r or a plain file, round-trips at its source's st_blocks"
    )
    func largeResourceForks() throws {
        let bench = try FidelityBench()
        let item = bytes("item")
        try bench.makeDirectory([item])
        try bench.makeFile([item, bytes("Icon\r")], Data())
        let icon = Array(randomBytes(200 << 10, seed: 31))
        try bench.setExtendedAttribute([item, bytes("Icon\r")], "com.apple.ResourceFork", icon)
        let data = randomBytes(Int(FolderBatch.largestFile) + 10, seed: 32)
        try bench.makeFile([item, bytes("written")], data)
        let large = Array(randomBytes(1_200_000, seed: 33))
        try bench.setExtendedAttribute([item, bytes("written")], "com.apple.ResourceFork", large)
        let acceptance = ContainerAcceptance(storage: .folder, byteCeiling: 1 << 30, decmpfsTypes: [], acceptsLZ4: true)

        let events = try bench.events(item, accepting: acceptance)
        #expect(events.filter { $0 == .resourceFork }.count == 2)
        #expect(try bench.roundTrip(item, accepting: acceptance, policy: .never) == item)
        let landed = try bench.facts(of: item, in: bench.destinationPath)
        #expect(landed[[item, bytes("Icon\r")]]?.resourceFork == icon)
        #expect(landed[[item, bytes("written")]]?.resourceFork == large)
        #expect(landed[[item, bytes("written")]]?.digest == SHA256.hash(Array(data)))
        #expect(landed[[item, bytes("Icon\r")]]?.carriedXattrs.isEmpty == true, "the fork is no attribute")
        for name in ["Icon\r", "written"] {
            let fork = "/item/" + name + "/..namedfork/rsrc"
            #expect(
                try rawStatus(bench.destinationPath + fork).st_blocks == rawStatus(bench.sourcePath + fork).st_blocks,
                "st_blocks of \(name)'s resource fork")
        }
    }

    // MARK: - The confirmation

    @Test("a flag write that does not stick is not confirmed: the entry fails by name and nothing remains")
    func unconfirmedFlag() throws {
        let landing = try Landing(kernelContainment: true)
        let sample = try CompressedSample.read("/bin/ls", on: fileSystem)
        let unsticking = InterposedFileSystem(dropsCompressedFlags: true)
        for (name, depth, inFolder) in [("held", UInt32(1), true), ("root", 0, false)] {
            var header = file(inFolder ? name : "", depth: depth, size: 0)
            header.decmpfs.attribute = Data(sample.attribute)
            header.resourceForkSize = UInt64(sample.resourceFork.count)
            let writer = TreeWriter(
                name: .exactly(inFolder ? bytes("r") : bytes(name)), fileSystem: unsticking,
                destination: try landing.openDestination(),
                destinationPathByteCount: landing.destinationPath.utf8.count,
                accepting: ContainerAcceptance(
                    storage: inFolder ? .folder : .file, byteCeiling: 1 << 30, decmpfsTypes: [8], acceptsLZ4: false))
            let path = depth == 0 ? [bytes(name)] : [bytes("r"), bytes(name)]
            let file: [TreeEvent] = [.beginFile(header), .resourceFork, .bytes(Data(sample.resourceFork)), .finishFile]
            let events = inFolder ? [.enterDirectory(directory(depth: 0))] + file + [.leaveDirectory] : file
            var refusal: TreeWriteFailure?
            do {
                for event in events { try writer.write(event) }
            } catch {
                refusal = error
            }
            let failure = try #require(refusal)
            #expect(failure.path == path)
            #expect(
                failure.reason
                    == .notCompressed(.unconfirmed(flags: 0, size: 0, logicalSize: sample.logicalSize)))
            #expect(failure.wireError.code == .itemDecmpfsRefused)
            try landing.expectNothingOutside()
        }
    }

    /// The adversarial review's probe P7-B: decmpfs storage with no compressed bytes where its type keeps them
    /// used to land, pass the confirmation, and publish a file that reads as nothing or fails to open.
    @Test("decmpfs storage with no payload where its type keeps it is refused by name, for every type the kernel reads")
    func missingPayloadRefused() throws {
        for type in DecmpfsMatrix.types(for: DecmpfsMatrix.Kernel(major: 27, minor: 2)).sorted() {
            let landing = try Landing(kernelContainment: true)
            let header = compressedFile("t\(type)", depth: 1, type: type, logicalSize: 100_000, resourceForkSize: 0)
            var refusal: TreeWriteFailure?
            let writer = try landing.writer(.folder, decmpfsTypes: [type])
            do {
                for event: TreeEvent in [.enterDirectory(directory(depth: 0)), .beginFile(header)] {
                    try writer.write(event)
                }
            } catch {
                refusal = error
            }
            #expect(
                refusal
                    == TreeWriteFailure(
                        path: [bytes("r"), bytes("t\(type)")], reason: .container(.decmpfsPayloadMissing(type))),
                "type \(type)")
            try landing.expectNothingOutside()
        }
    }

    // MARK: - A volume that stores no compressed file

    /// exFAT cannot rename without replacing (`VOL_CAP_INT_RENAME_EXCL` clear), so each item publishes onto its own
    /// claim of the name — an empty file, or an empty folder — and Keep Both counts past a name exFAT folds case
    /// onto.
    @Test("an exFAT destination accepts no type, and files and folders land there plain, onto their own claims")
    func exFATDestination() throws {
        let volume = try ExFATVolume()
        let exFAT = try fileSystem.openDirectory(bytes(volume.mountPoint), in: AT_FDCWD)
        defer { fileSystem.close(exFAT) }
        #expect(try !fileSystem.volumeStoresCompressedFiles(exFAT))
        #expect(try !fileSystem.renamesExclusively(in: exFAT))
        let types = try DecmpfsMatrix.acceptedTypes(landingIn: exFAT, on: fileSystem)
        #expect(types.isEmpty)

        let bench = try FidelityBench()
        let item = bytes("item")
        try bench.makeDirectory([item])
        for (source, name) in [("/bin/ls", "ls"), ("/usr/bin/pp", "pp")] {
            try #require(copyfile(source, bench.sourcePath + "/item/" + name, nil, copyfile_flags_t(COPYFILE_ALL)) == 0)
        }
        try #require(mkdir(volume.mountPoint + "/ITEM", 0o755) == 0)
        let landings: [(PublishName, [UInt8])] = [
            (.exactly(bytes("Landed")), bytes("Landed")), (.keepingBoth(bytes("item")), bytes("item 2")),
        ]
        for (publishing, landed) in landings {
            let acceptance = ContainerAcceptance(
                storage: .folder, byteCeiling: 1 << 30, decmpfsTypes: types, acceptsLZ4: false)
            let reader = try TreeReader(fileSystem: fileSystem, root: bench.path([item]), accepting: acceptance)
            let writer = TreeWriter(
                name: publishing, fileSystem: fileSystem,
                destination: try fileSystem.openDirectory(bytes(volume.mountPoint), in: AT_FDCWD),
                destinationPathByteCount: volume.mountPoint.utf8.count, accepting: acceptance)
            while let event = try reader.next() { try writer.write(event) }
            #expect(try writer.publish() == landed)
            for file in ["ls", "pp"] {
                let path = volume.mountPoint + "/" + String(decoding: landed, as: UTF8.self) + "/" + file
                #expect(try rawStatus(path).st_flags & UInt32(UF_COMPRESSED) == 0)
                #expect(try contents(of: path) == contents(of: bench.sourcePath + "/item/" + file))
            }
        }

        try #require(close(open(volume.mountPoint + "/LS", O_WRONLY | O_CREAT | O_EXCL, 0o644)) == 0)
        let fileAcceptance = ContainerAcceptance(
            storage: .file, byteCeiling: 1 << 30, decmpfsTypes: [], acceptsLZ4: false)
        for (publishing, landed) in [(PublishName.exactly(bytes("tool")), "tool"), (.keepingBoth(bytes("ls")), "ls 2")]
        {
            let reader = try TreeReader(
                fileSystem: fileSystem, root: bench.path([item, bytes("ls")]), accepting: fileAcceptance)
            let writer = TreeWriter(
                name: publishing, fileSystem: fileSystem,
                destination: try fileSystem.openDirectory(bytes(volume.mountPoint), in: AT_FDCWD),
                destinationPathByteCount: volume.mountPoint.utf8.count, accepting: fileAcceptance)
            while let event = try reader.next() { try writer.write(event) }
            #expect(try writer.publish() == bytes(landed))
            #expect(try contents(of: volume.mountPoint + "/" + landed) == contents(of: "/bin/ls"))
        }
        #expect(try contents(of: volume.mountPoint + "/LS").isEmpty)
        let left = try fileSystem.names(in: exFAT).map { String(decoding: $0, as: UTF8.self) }
            .filter { !$0.hasPrefix("._") && !$0.hasPrefix(".fseventsd") }
        #expect(left.sorted() == ["ITEM", "LS", "Landed", "item 2", "ls 2", "tool"].sorted())
    }

    @Test("decmpfs storage forced onto exFAT fails by name: the volume refuses the flag")
    func exFATRefusesTheFlag() throws {
        let volume = try ExFATVolume()
        let sample = try CompressedSample.read("/bin/ls", on: fileSystem)
        var header = file(depth: 0, size: 0)
        header.decmpfs.attribute = Data(sample.attribute)
        header.resourceForkSize = UInt64(sample.resourceFork.count)
        let acceptance = ContainerAcceptance(storage: .file, byteCeiling: 1 << 30, decmpfsTypes: [8], acceptsLZ4: false)
        let writer = TreeWriter(
            name: .exactly(bytes("ls")), fileSystem: fileSystem,
            destination: try fileSystem.openDirectory(bytes(volume.mountPoint), in: AT_FDCWD),
            destinationPathByteCount: volume.mountPoint.utf8.count, accepting: acceptance)
        let events: [TreeEvent] = [.beginFile(header), .resourceFork, .bytes(Data(sample.resourceFork)), .finishFile]
        let refusal = try #require(Self.failure(writing: events, to: writer))
        #expect(refusal.path == [bytes("ls")])
        #expect(refusal.reason == .notCompressed(.flagRefused(TreeFileSystemError(code: EINVAL))))
        #expect(refusal.wireError.code == .itemDecmpfsRefused)
        let mount = try fileSystem.openDirectory(bytes(volume.mountPoint), in: AT_FDCWD)
        defer { fileSystem.close(mount) }
        let left = try fileSystem.names(in: mount)
        #expect(
            left.filter { !$0.starts(with: Array("._".utf8)) && !$0.starts(with: Array(".fseventsd".utf8)) }.isEmpty)
    }
}

// MARK: - The hazards after the flag

/// What a call made after `UF_COMPRESSED` is set does to the file: the costs note's finding 3 table
/// (docs/research/2026-10-26-decmpfs-pass-through-costs.md), for `/bin/ls` (type 8), `/usr/bin/pp` (type 9) and
/// a type-4 file, each recreated through the system calls before the one call.
@Suite("decmpfs hazards after the flag")
struct DecmpfsHazardTests {
    enum Outcome: Equatable {
        /// Still compressed, every byte as it was.
        case intact
        /// The flag cleared and nothing left to read.
        case emptied
        /// The flag cleared and every byte as it was, now stored plainly.
        case decompressed
    }

    /// One call made on the file's creation descriptor, or on its path.
    struct Call: CustomStringConvertible, Sendable {
        let description: String
        let outcome: Outcome
        let make: @Sendable (_ descriptor: Int32, _ path: String, _ fileSystem: POSIXTreeFileSystem) throws -> Void
    }

    static let hidden = UInt32(UF_HIDDEN)
    static let compressed = UInt32(UF_COMPRESSED)

    static let calls: [Call] = [
        Call(description: "fchflags(0)", outcome: .emptied) { descriptor, _, _ in
            #expect(fchflags(descriptor, 0) == 0)
        },
        Call(description: "fchflags(UF_HIDDEN)", outcome: .emptied) { descriptor, _, _ in
            #expect(fchflags(descriptor, Self.hidden) == 0)
        },
        Call(description: "fchflags(UF_NODUMP)", outcome: .emptied) { descriptor, _, _ in
            #expect(fchflags(descriptor, UInt32(UF_NODUMP)) == 0)
        },
        Call(description: "chflags by path", outcome: .emptied) { _, path, _ in
            #expect(chflags(path, Self.hidden) == 0)
        },
        Call(description: "lchflags by path", outcome: .emptied) { _, path, _ in
            #expect(lchflags(path, Self.hidden) == 0)
        },
        Call(description: "setAttributes flags alone, lacking UF_COMPRESSED", outcome: .emptied) { descriptor, _, fs in
            try fs.setAttributes(TreeEntryAttributes(flags: Self.hidden), of: .descriptor(descriptor))
        },
        Call(description: "setAttributes times, mode and flags, lacking UF_COMPRESSED", outcome: .emptied) {
            descriptor, _, fs in
            let time = FileTime(seconds: 1_600_000_000, nanoseconds: 0)
            try fs.setAttributes(
                TreeEntryAttributes(permissions: 0o644, flags: Self.hidden, modificationTime: time, birthTime: time),
                of: .descriptor(descriptor))
        },
        Call(description: "fchflags with UF_COMPRESSED", outcome: .intact) { descriptor, _, _ in
            #expect(fchflags(descriptor, Self.hidden | Self.compressed) == 0)
        },
        Call(description: "setAttributes flags with UF_COMPRESSED", outcome: .intact) { descriptor, _, fs in
            try fs.setAttributes(TreeEntryAttributes(flags: Self.hidden | Self.compressed), of: .descriptor(descriptor))
        },
        Call(description: "setCompressedFlags", outcome: .intact) { descriptor, _, fs in
            try fs.setCompressedFlags(Self.hidden, of: descriptor)
        },
        Call(description: "fremovexattr(com.apple.decmpfs)", outcome: .emptied) { descriptor, _, _ in
            #expect(fremovexattr(descriptor, "com.apple.decmpfs", XATTR_SHOWCOMPRESSION) == 0)
        },
        Call(description: "ftruncate(0)", outcome: .emptied) { descriptor, _, _ in
            #expect(ftruncate(descriptor, 0) == 0)
        },
        Call(description: "fsetxattr(com.apple.decmpfs) again", outcome: .decompressed) { descriptor, path, fs in
            let attribute = try #require(
                try fs.compressedStorage(of: descriptor, maxByteCount: DecmpfsHeader.maxAttributeByteCount))
            #expect(
                fsetxattr(descriptor, "com.apple.decmpfs", attribute, attribute.count, 0, XATTR_SHOWCOMPRESSION) == 0)
        },
        Call(description: "open(O_RDWR)", outcome: .decompressed) { _, path, _ in
            let opened = open(path, O_RDWR)
            #expect(opened >= 0)
            close(opened)
        },
        Call(description: "open(O_WRONLY)", outcome: .decompressed) { _, path, _ in
            let opened = open(path, O_WRONLY)
            #expect(opened >= 0)
            close(opened)
        },
        Call(description: "write on the creation descriptor", outcome: .intact) { descriptor, _, _ in
            #expect(write(descriptor, "x", 1) == -1 && errno == EACCES)
        },
        Call(description: "setAttributes times", outcome: .intact) { descriptor, _, fs in
            let time = FileTime(seconds: 1_600_000_000, nanoseconds: 5)
            try fs.setAttributes(
                TreeEntryAttributes(modificationTime: time, birthTime: time), of: .descriptor(descriptor))
        },
        Call(description: "setAttributes mode", outcome: .intact) { descriptor, _, fs in
            try fs.setAttributes(TreeEntryAttributes(permissions: 0o600), of: .descriptor(descriptor))
        },
        Call(description: "utimes", outcome: .intact) { _, path, _ in
            #expect(utimes(path, nil) == 0)
        },
        Call(description: "fchmod", outcome: .intact) { descriptor, _, _ in
            #expect(fchmod(descriptor, 0o600) == 0)
        },
        Call(description: "fchown to the receiver", outcome: .intact) { descriptor, _, _ in
            #expect(fchown(descriptor, getuid(), getegid()) == 0)
        },
        Call(description: "fsetxattr and fremovexattr of user.test", outcome: .intact) { descriptor, _, _ in
            #expect(fsetxattr(descriptor, "user.test", "v", 1, 0, 0) == 0)
            #expect(fremovexattr(descriptor, "user.test", 0) == 0)
        },
        Call(description: "fsetxattr of com.apple.quarantine", outcome: .intact) { descriptor, _, _ in
            let value = "0081;00000000;Kernova;"
            #expect(fsetxattr(descriptor, "com.apple.quarantine", value, value.utf8.count, 0, 0) == 0)
        },
        Call(description: "open(O_RDONLY)", outcome: .intact) { _, path, _ in
            let opened = open(path, O_RDONLY)
            #expect(opened >= 0)
            close(opened)
        },
        Call(description: "rename within the folder", outcome: .intact) { _, path, _ in
            #expect(rename(path, path + ".moved") == 0)
            #expect(rename(path + ".moved", path) == 0)
        },
    ]

    static let sources = ["/bin/ls", "/usr/bin/pp", "type 4"]

    @Test("each call after the flag leaves the file as the costs note's table says", arguments: sources, calls)
    func hazard(source: String, call: Call) throws {
        let fileSystem = POSIXTreeFileSystem()
        let sample =
            source == "type 4"
            ? try #require(CompressedSample.built(type: 4, plain: sampleText(400_000, seed: 4)))
            : try CompressedSample.read(source, on: fileSystem)
        let scratch = try PortableScratchDirectory(prefix: "decmpfs-hazard")
        let path = scratch.path + "/file"
        let descriptor = try createCompressedDirectly(path, sample)
        try #require(try rawStatus(path).st_flags & UInt32(UF_COMPRESSED) != 0)
        try call.make(descriptor, path, fileSystem)
        close(descriptor)
        let status = try rawStatus(path)
        let isCompressed = status.st_flags & UInt32(UF_COMPRESSED) != 0
        let content = try contents(of: path)
        let outcome: Outcome? =
            switch (isCompressed, status.st_size, content == sample.plain) {
            case (true, Int64(sample.plain.count), true): .intact
            case (false, 0, _) where content.isEmpty: .emptied
            case (false, Int64(sample.plain.count), true): .decompressed
            default: nil
            }
        #expect(outcome == call.outcome, "\(call) on \(source)")
    }
}
#endif
