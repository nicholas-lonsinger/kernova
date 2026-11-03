#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaContainer
import KernovaContainerPipeline
import KernovaDigest
import KernovaFileTree
import KernovaTreeTransfer
import KernovaWire

/// `kernova-bench tree`: one item moved through a transfer's whole pipeline in this process — `TreeReader`,
/// `ContainerEncodePipeline`, the container's bytes, then `TreeReceiver` (`ContainerDecodePipeline` feeding
/// `TreeWriter`) — and the landed tree compared with its source, entry by entry.
///
/// The pull accepts what a pull landing in the destination would: the decmpfs types
/// `DecmpfsMatrix.acceptedTypes(landingIn:on:kernel:)` gives for it, and LZ4. The sender compresses as
/// `--compression` says: `policy` (the default) as `TransferCompression.forSending` chooses for a guest-to-host
/// send on this machine's active cores, `lz4` as that policy does on any core count, `none` never.
struct TreeBench {
    enum Compression: String {
        case policy
        case lz4
        case none
    }

    struct Options {
        var compression = Compression.policy
        var decodingWorkers: Int?
        var source = ""
        var destination = ""

        init(parsing arguments: [String]) throws(UsageError) {
            var remaining = arguments[...]
            var paths: [String] = []
            while let argument = remaining.popFirst() {
                switch argument {
                case "--compression":
                    guard let text = remaining.popFirst(), let value = Compression(rawValue: text) else {
                        throw UsageError(message: "--compression takes policy, lz4 or none")
                    }
                    compression = value
                case "--decode-workers":
                    guard let text = remaining.popFirst(), let count = Int(text), count >= 0 else {
                        throw UsageError(message: "--decode-workers takes an integer of at least 0")
                    }
                    decodingWorkers = count
                default:
                    paths.append(argument)
                }
            }
            guard paths.count == 2 else { throw UsageError(message: "tree takes a source and a destination") }
            source = paths[0]
            destination = paths[1]
        }
    }

    let options: Options
    let fileSystem = POSIXTreeFileSystem()

    func run() {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let (parentPath, itemName) = Self.split(options.source)
        let parent = attempt("open \(parentPath)") { () throws(TreeFileSystemError) in
            try fileSystem.openDirectory(Array(parentPath.utf8), in: AT_FDCWD)
        }
        defer { fileSystem.close(parent) }
        let status = attempt("stat \(options.source)") { () throws(TreeFileSystemError) in
            try fileSystem.status(of: itemName, in: parent)
        }
        let destinationBytes = Array(options.destination.utf8)
        let probe = attempt("open \(options.destination)") { () throws(TreeFileSystemError) in
            try fileSystem.openDirectory(destinationBytes, in: AT_FDCWD)
        }
        let decmpfsTypes = attempt("ask the destination's volume") { () throws(TreeFileSystemError) in
            try DecmpfsMatrix.acceptedTypes(landingIn: probe, on: fileSystem)
        }
        fileSystem.close(probe)
        let acceptance = ContainerAcceptance(
            storage: status.kind == .directory ? .folder : .file, byteCeiling: .max, decmpfsTypes: decmpfsTypes,
            acceptsLZ4: true)
        let compression =
            switch options.compression {
            case .policy: TransferCompression.forSending(.guestToHost, pullAcceptsLZ4: true, sendingCores: cores)
            case .lz4:
                TransferCompression.forSending(
                    .guestToHost, pullAcceptsLZ4: true,
                    sendingCores: max(cores, TransferCompression.minimumEncodingCores))
            case .none: TransferCompression.uncompressed
            }
        let decodingWorkers = options.decodingWorkers ?? TransferCompression.decodingWorkers(receivingCores: cores)

        print("kernova-bench tree")
        print("")
        print("- system: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("- active cores: \(cores)")
        print("- source: \(options.source)")
        print("- destination: \(options.destination)")
        print(
            "- decmpfs types accepted: \(decmpfsTypes.isEmpty ? "none" : decmpfsTypes.sorted().map(String.init).joined(separator: ", "))"
        )
        print(
            "- compression: \(options.compression.rawValue): files as \(compression.storesLZ4 ? "LZ4" : "plain") storage, "
                + "\(compression.encodingWorkers) encoding lanes, \(decodingWorkers) decoding lanes")
        print("- load before: \(loadAverage())")

        let transfer = move(
            itemName, in: parent, acceptance: acceptance, compression: compression, decodingWorkers: decodingWorkers)
        print("- load after: \(loadAverage())")
        print("")
        print("## Transfer")
        print("")
        print(
            "- wall: \(fixed(transfer.wall, 3)) s (sender \(fixed(transfer.sending, 3)) s, receiver \(fixed(transfer.receiving, 3)) s, in one thread with their lanes)"
        )
        print("- container bytes: \(transfer.containerBytes)")
        print(
            "- entries: \(transfer.entries) (\(transfer.directories) directories, \(transfer.files) files, \(transfer.symlinks) symlinks)"
        )
        print(
            "- file storage: \(transfer.storage.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))"
        )
        print("")

        let landedPath = options.destination + "/" + String(decoding: transfer.landedName, as: UTF8.self)
        var comparison = Comparison(acceptedTypes: decmpfsTypes)
        let destination = attempt("open \(options.destination)") { () throws(TreeFileSystemError) in
            try fileSystem.openDirectory(destinationBytes, in: AT_FDCWD)
        }
        defer { fileSystem.close(destination) }
        compare(itemName, in: parent, landed: transfer.landedName, in: destination, path: itemName, into: &comparison)
        comparison.report(source: options.source, landed: landedPath)
    }

    // MARK: - Moving

    struct Transfer {
        var wall = 0.0
        var sending = 0.0
        var receiving = 0.0
        var containerBytes = 0
        var entries = 0
        var directories = 0
        var files = 0
        var symlinks = 0
        /// Files by the storage their header declared: plain, lz4, or decmpfs and its type.
        var storage: [String: Int] = [:]
        var landedName: [UInt8] = []
    }

    private func move(
        _ name: [UInt8], in parent: Int32, acceptance: ContainerAcceptance, compression: TransferCompression,
        decodingWorkers: Int
    ) -> Transfer {
        let sending = compression.sending(acceptance)
        let destinationBytes = Array(options.destination.utf8)
        let destination = attempt("open \(options.destination)") { () throws(TreeFileSystemError) in
            try fileSystem.openDirectory(destinationBytes, in: AT_FDCWD)
        }
        var transfer = Transfer()
        let start = DispatchTime.now().uptimeNanoseconds
        func since(_ mark: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - mark) * 1e-9 }
        do {
            let reader = try TreeReader(fileSystem: fileSystem, item: name, in: parent, accepting: sending)
            let encoder = ContainerEncodePipeline(
                accepting: sending, policy: compression.chunkPolicy, workers: compression.encodingWorkers)
            let receiver = TreeReceiver(
                accepting: acceptance, decodingWorkers: decodingWorkers, fileSystem: fileSystem,
                destination: destination, destinationPathByteCount: destinationBytes.count)
            while true {
                let sendStart = DispatchTime.now().uptimeNanoseconds
                guard let event = try reader.next() else { break }
                count(event, into: &transfer)
                let bytes = try encoder.encode(event)
                transfer.sending += since(sendStart)
                transfer.containerBytes += bytes.count
                let receiveStart = DispatchTime.now().uptimeNanoseconds
                try receiver.receive(bytes)
                transfer.receiving += since(receiveStart)
            }
            let finishStart = DispatchTime.now().uptimeNanoseconds
            transfer.landedName = try receiver.finish()
            transfer.receiving += since(finishStart)
        } catch {
            KernovaBench.fail("the transfer failed: \(error)")
        }
        transfer.wall = since(start)
        return transfer
    }

    private func count(_ event: TreeEvent, into transfer: inout Transfer) {
        switch event {
        case .enterDirectory:
            transfer.entries += 1
            transfer.directories += 1
        case .symlink:
            transfer.entries += 1
            transfer.symlinks += 1
        case .beginFile(let header):
            transfer.entries += 1
            transfer.files += 1
            let storage =
                switch header.storage {
                case .plain: "plain"
                case .lz4: "lz4"
                case .decmpfs(let decmpfs):
                    "decmpfs type "
                        + ((try? DecmpfsHeader(attribute: decmpfs.attribute)).map { String($0.compressionType) } ?? "?")
                case nil: "none"
                }
            transfer.storage[storage, default: 0] += 1
        default:
            break
        }
    }

    // MARK: - Comparing

    /// What is compared of one entry.
    struct Facts {
        var kind: FileKind
        var permissions: UInt32
        var flags: UInt32
        var compressed: Bool
        var modificationTime: FileTime
        var birthTime: FileTime?
        var size: Int64 = 0
        var linkTarget: [UInt8]?
        var carriedXattrs: [[UInt8]: [UInt8]] = [:]
        var resourceFork: [UInt8]?
        var digest: [UInt8]?
        /// The `com.apple.decmpfs` attribute, for a compressed file.
        var decmpfsAttribute: [UInt8]?
        /// The SHA-256 of the resource fork as the compressed storage holds it, for a compressed file.
        var compressedForkDigest: [UInt8]?
        /// 512-byte blocks, `st_blocks`.
        var blocks: Int64
    }

    /// The comparison of a source tree with its landing.
    struct Comparison {
        let acceptedTypes: Set<UInt32>
        var entries = 0
        var mismatches: [String: [String]] = [:]
        var sourceBlocks: Int64 = 0
        var landedBlocks: Int64 = 0
        /// Source compressed files by decmpfs type.
        var sourceTypes: [UInt32: Int] = [:]
        /// Landed compressed files by decmpfs type.
        var landedTypes: [UInt32: Int] = [:]
        /// Compressed files whose type was accepted that landed with the same attribute and compressed fork.
        var storagePreserved = 0
        /// Compressed files whose type was not accepted, which land as plain bytes.
        var landedPlainByAcceptance = 0
        /// Files that took more or fewer blocks than their source: the path and both block counts.
        var grew: [(path: String, source: Int64, landed: Int64, type: UInt32?, fork: Int)] = []
        var shrank: [(path: String, source: Int64, landed: Int64)] = []

        init(acceptedTypes: Set<UInt32>) {
            self.acceptedTypes = acceptedTypes
        }

        mutating func mismatch(_ field: String, _ path: String) {
            mismatches[field, default: []].append(path)
        }

        func report(source: String, landed: String) {
            func kib(_ blocks: Int64) -> String { "\(blocks / 2) KiB" }
            func types(_ types: [UInt32: Int]) -> String {
                types.isEmpty
                    ? "none"
                    : types.sorted { $0.key < $1.key }.map { "type \($0.key): \($0.value)" }
                        .joined(separator: ", ")
            }
            print("## Landed tree")
            print("")
            print("- landed: \(landed)")
            print("- entries compared: \(entries)")
            print(
                "- on disk, summed st_blocks: source \(kib(sourceBlocks)), landed \(kib(landedBlocks)) (\(landedBlocks >= sourceBlocks ? "+" : "-")\(kib(abs(landedBlocks - sourceBlocks))))"
            )
            print("- source compressed files: \(types(sourceTypes))")
            print("- landed compressed files: \(types(landedTypes))")
            print("- decmpfs storage preserved (same attribute and compressed fork bytes): \(storagePreserved)")
            print("- compressed files of a type not accepted, landed as plain bytes: \(landedPlainByAcceptance)")
            print("")
            print("## Fidelity")
            print("")
            if mismatches.isEmpty {
                print(
                    "- every entry matches: type, mode, allowed flags, compression, mtime, birth time, size, "
                        + "symlink target, allowlisted xattrs, resource fork, content SHA-256, decmpfs storage")
            } else {
                for (field, paths) in mismatches.sorted(by: { $0.key < $1.key }) {
                    print("- \(field): \(paths.count) entries, first: \(paths.prefix(5).joined(separator: ", "))")
                }
            }
            print("")
            print("## Files whose blocks differ")
            print("")
            let extra = grew.reduce(Int64(0)) { $0 + $1.landed - $1.source }
            let fewer = shrank.reduce(Int64(0)) { $0 + $1.source - $1.landed }
            print("- grew: \(grew.count) files, +\(kib(extra))")
            var byType: [String: (count: Int, blocks: Int64)] = [:]
            for file in grew {
                let key = file.type.map { "decmpfs type \($0)" } ?? "uncompressed"
                byType[key, default: (0, 0)].count += 1
                byType[key, default: (0, 0)].blocks += file.landed - file.source
            }
            for (key, value) in byType.sorted(by: { $0.key < $1.key }) {
                print("  - \(key): \(value.count) files, +\(kib(value.blocks))")
            }
            let forks = grew.map(\.fork).sorted()
            if let smallest = forks.first, let largest = forks.last {
                print(
                    "  - their compressed forks: \(smallest) to \(largest) bytes; "
                        + "\(forks.filter { $0 > ContainerEncoder.chunkByteCount }.count) longer than one chunk "
                        + "(\(ContainerEncoder.chunkByteCount) bytes)")
            }
            let singleChunk = grew.filter { $0.fork <= ContainerEncoder.chunkByteCount }
            if !singleChunk.isEmpty {
                print(
                    "  - grew with a fork of at most one chunk: \(singleChunk.count), first: "
                        + singleChunk.prefix(3).map(\.path).joined(separator: ", "))
            }
            for file in grew.sorted(by: { $0.landed - $0.source > $1.landed - $1.source }).prefix(10) {
                print("  - \(file.path): \(file.source) → \(file.landed) blocks, fork \(file.fork) bytes")
            }
            print("- shrank: \(shrank.count) files, -\(kib(fewer))")
            for file in shrank.prefix(10) {
                print("  - \(file.path): \(file.source) → \(file.landed) blocks")
            }
        }
    }

    /// Compares the entry `name` in `directory` with the entry `landedName` in `landedDirectory`, and everything
    /// beneath them.
    private func compare(
        _ name: [UInt8], in directory: Int32, landed landedName: [UInt8], in landedDirectory: Int32, path: [UInt8],
        into comparison: inout Comparison
    ) {
        let shown = String(decoding: path, as: UTF8.self)
        comparison.entries += 1
        let source = facts(of: name, in: directory, path: shown)
        let landed = facts(of: landedName, in: landedDirectory, path: shown)
        comparison.sourceBlocks += source.blocks
        comparison.landedBlocks += landed.blocks
        func check<Value: Equatable>(_ field: String, _ value: (Facts) -> Value) {
            if value(source) != value(landed) { comparison.mismatch(field, shown) }
        }
        check("type") { $0.kind }
        guard source.kind == landed.kind else { return }
        check("mode") { $0.permissions }
        check("allowed flags") { $0.flags & ValidatedEntry.allowedDarwinFlags }
        check("mtime") { $0.modificationTime }
        check("birth time") { $0.birthTime }
        check("allowlisted xattrs") { $0.carriedXattrs }
        switch source.kind {
        case .regular:
            check("size") { $0.size }
            check("content SHA-256") { $0.digest }
            check("resource fork") { $0.resourceFork }
            let sourceType = source.decmpfsAttribute.flatMap { try? DecmpfsHeader(attribute: Data($0)) }?
                .compressionType
            let landedType = landed.decmpfsAttribute.flatMap { try? DecmpfsHeader(attribute: Data($0)) }?
                .compressionType
            if let sourceType { comparison.sourceTypes[sourceType, default: 0] += 1 }
            if let landedType { comparison.landedTypes[landedType, default: 0] += 1 }
            if let sourceType, comparison.acceptedTypes.contains(sourceType) {
                if landed.compressed, source.decmpfsAttribute == landed.decmpfsAttribute,
                    source.compressedForkDigest == landed.compressedForkDigest
                {
                    comparison.storagePreserved += 1
                } else {
                    comparison.mismatch("decmpfs storage", shown)
                }
            } else if source.compressed {
                comparison.landedPlainByAcceptance += 1
                if landed.compressed { comparison.mismatch("compressed though its type was not accepted", shown) }
            } else if landed.compressed {
                comparison.mismatch("compressed though its source is not", shown)
            }
            if landed.blocks > source.blocks {
                let fork = landed.decmpfsAttribute == nil ? 0 : compressedForkSize(of: landedName, in: landedDirectory)
                comparison.grew.append((shown, source.blocks, landed.blocks, landedType, fork))
            } else if landed.blocks < source.blocks {
                comparison.shrank.append((shown, source.blocks, landed.blocks))
            }
        case .symbolicLink:
            check("symlink target") { $0.linkTarget }
        case .directory:
            let sourceDescriptor = open(name, in: directory, path: shown)
            let landedDescriptor = open(landedName, in: landedDirectory, path: shown)
            defer {
                fileSystem.close(sourceDescriptor)
                fileSystem.close(landedDescriptor)
            }
            let sourceNames = Set(names(in: sourceDescriptor, path: shown))
            let landedNames = Set(names(in: landedDescriptor, path: shown))
            for missing in sourceNames.subtracting(landedNames) {
                comparison.mismatch("missing from the landing", shown + "/" + String(decoding: missing, as: UTF8.self))
            }
            for extra in landedNames.subtracting(sourceNames) {
                comparison.mismatch("only in the landing", shown + "/" + String(decoding: extra, as: UTF8.self))
            }
            for child in sourceNames.intersection(landedNames).sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                compare(
                    child, in: sourceDescriptor, landed: child, in: landedDescriptor, path: path + [0x2F] + child,
                    into: &comparison)
            }
        default:
            break
        }
    }

    private func facts(of name: [UInt8], in directory: Int32, path: String) -> Facts {
        let status = attempt("stat \(path)") { () throws(TreeFileSystemError) in
            try fileSystem.status(of: name, in: directory)
        }
        var raw = stat()
        let statted = (name.map { CChar(bitPattern: $0) } + [0]).withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { fstatat(directory, $0, &raw, AT_SYMLINK_NOFOLLOW) } ?? -1
        }
        guard statted == 0 else { KernovaBench.fail("stat \(path): errno \(errno)") }
        var facts = Facts(
            kind: status.kind, permissions: status.permissions, flags: status.flags, compressed: status.isCompressed,
            modificationTime: status.modificationTime, birthTime: status.birthTime, blocks: Int64(raw.st_blocks))
        attempt("read \(path)") { () throws(TreeFileSystemError) in
            func readXattrs(_ target: TreeEntryTarget) throws(TreeFileSystemError) {
                for attribute in try fileSystem.extendedAttributeNames(of: target)
                where ValidatedEntry.isAllowedXattrName(Data(attribute)) {
                    facts.carriedXattrs[attribute] = try fileSystem.extendedAttribute(
                        attribute, of: target, maxByteCount: 1 << 24)
                }
            }
            switch status.kind {
            case .regular:
                facts.size = status.size
                let descriptor = try fileSystem.openFile(name, in: directory)
                defer { fileSystem.close(descriptor) }
                try readXattrs(.descriptor(descriptor))
                facts.digest = try digest(of: descriptor)
                facts.resourceFork = try resourceFork(of: descriptor, showingCompression: false)
                if status.isCompressed {
                    facts.decmpfsAttribute = try fileSystem.compressedStorage(
                        of: descriptor, maxByteCount: DecmpfsHeader.maxAttributeByteCount)
                    facts.compressedForkDigest = try resourceFork(of: descriptor, showingCompression: true)
                        .map { SHA256.hash($0) }
                }
            case .directory:
                let descriptor = try fileSystem.openDirectory(name, in: directory)
                defer { fileSystem.close(descriptor) }
                try readXattrs(.descriptor(descriptor))
            case .symbolicLink:
                facts.linkTarget = try fileSystem.linkTarget(of: name, in: directory)
                try readXattrs(.symlink(name, in: directory))
            default:
                break
            }
        }
        return facts
    }

    private func digest(of descriptor: Int32) throws(TreeFileSystemError) -> [UInt8] {
        var hasher = SHA256()
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = try fileSystem.read(descriptor, into: buffer)
            guard count > 0 else { break }
            hasher.update(UnsafeRawBufferPointer(rebasing: buffer[..<count]))
        }
        return hasher.finalize()
    }

    private func resourceFork(of descriptor: Int32, showingCompression: Bool) throws(TreeFileSystemError) -> [UInt8]? {
        let size = try fileSystem.resourceForkSize(of: descriptor, showingCompression: showingCompression)
        guard size > 0 else { return nil }
        let fork = UnsafeMutableRawBufferPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { fork.deallocate() }
        var offset = 0
        while offset < fork.count {
            let count = try fileSystem.readResourceFork(
                descriptor, into: UnsafeMutableRawBufferPointer(rebasing: fork[offset...]), at: UInt64(offset),
                showingCompression: showingCompression)
            guard count > 0 else { break }
            offset += count
        }
        return Array(fork[..<offset])
    }

    private func compressedForkSize(of name: [UInt8], in directory: Int32) -> Int {
        guard let descriptor = try? fileSystem.openFile(name, in: directory) else { return 0 }
        defer { fileSystem.close(descriptor) }
        return Int((try? fileSystem.resourceForkSize(of: descriptor, showingCompression: true)) ?? 0)
    }

    private func open(_ name: [UInt8], in directory: Int32, path: String) -> Int32 {
        attempt("open \(path)") { () throws(TreeFileSystemError) in try fileSystem.openDirectory(name, in: directory) }
    }

    private func names(in directory: Int32, path: String) -> [[UInt8]] {
        attempt("list \(path)") { () throws(TreeFileSystemError) in try fileSystem.names(in: directory) }
    }

    /// `body`'s result, or the bench ends naming `what` failed.
    @discardableResult
    private func attempt<Result>(_ what: String, _ body: () throws(TreeFileSystemError) -> Result) -> Result {
        do {
            return try body()
        } catch {
            KernovaBench.fail("\(what) failed: \(error)")
        }
    }

    /// The directory holding `path` and the item's name in it.
    private static func split(_ path: String) -> (parent: String, name: [UInt8]) {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return (".", Array(trimmed.utf8)) }
        let parent = slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
        return (parent, Array(trimmed[trimmed.index(after: slash)...].utf8))
    }
}
#endif
