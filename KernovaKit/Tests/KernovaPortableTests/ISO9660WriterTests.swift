import KernovaISO9660
import KernovaPortableTestSupport
import Testing

#if os(Linux)
import Foundation
#endif

@Suite("ISO9660Writer")
struct ISO9660WriterTests {
    static let date = ISO9660Date(year: 2026, month: 1, day: 1)

    /// The agent disk's files, with a binary large enough to span sectors and ending mid-sector.
    static func entries() -> [ISO9660Entry] {
        let binary = (0..<(3 * 2048 + 517)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        return [
            ISO9660Entry(name: "install.sh", permissions: 0o755, bytes: Array("#!/bin/sh\necho install\n".utf8)),
            ISO9660Entry(name: "uninstall.sh", permissions: 0o755, bytes: Array("#!/bin/sh\necho remove\n".utf8)),
            ISO9660Entry(name: "kernova-agent", permissions: 0o755, size: UInt64(binary.count)) { sink in
                // In pieces, as a file read in chunks arrives.
                var offset = 0
                while offset < binary.count {
                    let end = min(offset + 1000, binary.count)
                    try sink(Array(binary[offset..<end]))
                    offset = end
                }
            },
            ISO9660Entry(name: "README.txt", permissions: 0o644, bytes: Array("Read me.\n".utf8)),
            ISO9660Entry(name: "LICENSES.txt", permissions: 0o644, bytes: Array("Licences.\n".utf8)),
        ]
    }

    static func write(_ entries: [ISO9660Entry], volume: String = "KERNOVA_AGENT") throws -> [UInt8] {
        var image: [UInt8] = []
        try ISO9660Writer(volumeIdentifier: volume, date: date).write(entries) { image += $0 }
        return image
    }

    @Test("The image reads back with its label, Rock Ridge names and modes, and each file's bytes")
    func readsBack() throws {
        let entries = Self.entries()
        let reader = try ISO9660Reader(try Self.write(entries))
        #expect(reader.volumeIdentifier == "KERNOVA_AGENT")
        #expect(reader.extensions == ["IEEE_P1282"])
        #expect(reader.rootMode == 0o040755)
        #expect(
            reader.files.map(\.identifier) == [
                "INSTALL.SH;1", "KERNOVA_.;1", "LICENSES.TXT;1", "README.TXT;1", "UNINSTAL.SH;1",
            ])
        let byName = Dictionary(uniqueKeysWithValues: reader.files.map { ($0.name, $0) })
        #expect(Set(byName.keys) == Set(entries.map(\.name)))
        for entry in entries {
            let file = try #require(byName[entry.name])
            var bytes: [UInt8] = []
            try entry.contents { bytes += $0 }
            #expect(file.bytes == bytes, "\(entry.name)")
            #expect(file.mode == 0o100000 | UInt32(entry.permissions), "\(entry.name)")
            #expect(file.links == 1)
            #expect(file.recordedYear == 2026)
        }
    }

    @Test("Two writes are byte-equal, whatever order the entries come in")
    func deterministic() throws {
        let first = try Self.write(Self.entries())
        #expect(try Self.write(Self.entries()) == first)
        #expect(try Self.write(Self.entries().reversed()) == first)
    }

    @Test("Names that map to one identifier get distinct identifiers, assigned in name order")
    func collidingIdentifiers() throws {
        let names = ["setup-b.sh", "setup_a.sh", "setup-a.sh"]
        let entries = names.map { ISO9660Entry(name: $0, permissions: 0o644, bytes: Array($0.utf8)) }
        let reader = try ISO9660Reader(try Self.write(entries))
        let identifiers = Dictionary(uniqueKeysWithValues: reader.files.map { ($0.name, $0.identifier) })
        #expect(
            identifiers == ["setup-a.sh": "SETUP_A.SH;1", "setup-b.sh": "SETUP_B.SH;1", "setup_a.sh": "SETUP_A1.SH;1"])
        #expect(reader.files.map { String(decoding: $0.bytes, as: UTF8.self) } == reader.files.map(\.name))
    }

    @Test("A directory too long for one sector continues into the next, no record crossing the boundary")
    func directorySpansSectors() throws {
        let entries = (0..<40).map { index in
            ISO9660Entry(
                name: "file-\(index)-" + String(repeating: "x", count: 60), permissions: 0o600, bytes: [UInt8(index)])
        }
        let reader = try ISO9660Reader(try Self.write(entries))
        #expect(reader.rootLength > 2048)
        #expect(reader.files.count == 40)
        #expect(Set(reader.files.map(\.name)) == Set(entries.map(\.name)))
        #expect(reader.files.allSatisfy { $0.mode == 0o100600 && $0.bytes.count == 1 })
    }

    @Test("An empty file takes no sector")
    func emptyFile() throws {
        let reader = try ISO9660Reader(
            try Self.write([ISO9660Entry(name: "empty", permissions: 0o644, bytes: [])]))
        #expect(reader.files.map(\.bytes) == [[]])
        // System area, two descriptors, two path tables, the root and its continuation area.
        #expect(reader.volumeSpaceSize == 22)
    }

    @Test(
        "Inputs the image cannot carry are refused before anything is written",
        arguments: [
            ([ISO9660Entry(name: "a/b", permissions: 0o644, bytes: [])], "KERNOVA", ISO9660Error.invalidName("a/b")),
            ([ISO9660Entry(name: "..", permissions: 0o644, bytes: [])], "KERNOVA", .invalidName("..")),
            ([ISO9660Entry(name: "", permissions: 0o644, bytes: [])], "KERNOVA", .invalidName("")),
            (
                [ISO9660Entry(name: "x", permissions: 0o10000, bytes: [])], "KERNOVA",
                .invalidPermissions(name: "x", permissions: 0o10000)
            ),
            (
                [ISO9660Entry(name: "x", permissions: 0o644, bytes: []), .init(name: "x", permissions: 0, bytes: [])],
                "KERNOVA", .duplicateName("x")
            ),
            ([], "kernova", .invalidVolumeIdentifier("kernova")),
            ([], "", .invalidVolumeIdentifier("")),
            ([], String(repeating: "A", count: 33), .invalidVolumeIdentifier(String(repeating: "A", count: 33))),
        ])
    func refused(entries: [ISO9660Entry], volume: String, error: ISO9660Error) {
        var written = 0
        #expect(throws: error) {
            try ISO9660Writer(volumeIdentifier: volume, date: Self.date).write(entries) { written += $0.count }
        }
        #expect(written == 0)
    }

    @Test("A file whose contents write other than its declared size fails the write")
    func sizeMismatch() {
        let entry = ISO9660Entry(name: "short", permissions: 0o644, size: 10) { sink in try sink([1, 2, 3]) }
        #expect(throws: ISO9660Error.sizeMismatch(name: "short", declared: 10, written: 3)) {
            try Self.write([entry])
        }
    }

    #if os(Linux)
    /// xorriso, the reference reader on Linux CI, lists the names and modes, and extracts the bytes.
    @Test("xorriso lists the names and modes, and osirrox extracts the same bytes and modes")
    func xorrisoAgrees() throws {
        let directory = try PortableScratchDirectory(prefix: "iso9660")
        let scratch = directory.url
        let iso = scratch.appending(path: "agent.iso")
        let entries = Self.entries()
        try Data(try Self.write(entries)).write(to: iso)

        let listing = try Self.run(["xorriso", "-indev", iso.path, "-find", "/", "-type", "f", "-exec", "lsdm"])
        var listed: [String: String] = [:]
        for line in listing.split(separator: "\n") where line.hasPrefix("-") {
            let mode = String(line.prefix(10))
            guard let quoted = line.split(separator: "'").dropFirst().first else { continue }
            listed[String(quoted.dropFirst())] = mode
        }
        #expect(
            listed == [
                "install.sh": "-rwxr-xr-x", "uninstall.sh": "-rwxr-xr-x", "kernova-agent": "-rwxr-xr-x",
                "README.txt": "-rw-r--r--", "LICENSES.txt": "-rw-r--r--",
            ], "\(listing)")

        let extracted = scratch.appending(path: "extracted")
        _ = try Self.run(["xorriso", "-osirrox", "on", "-indev", iso.path, "-extract", "/", extracted.path])
        for entry in entries {
            let path = extracted.appending(path: entry.name).path
            var bytes: [UInt8] = []
            try entry.contents { bytes += $0 }
            #expect(FileManager.default.contents(atPath: path).map(Array.init) == bytes, "\(entry.name)")
            let permissions = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?
                .intValue
            #expect(permissions == Int(entry.permissions), "\(entry.name)")
        }
    }

    /// Runs `arguments` from PATH and answers its standard output; a non-zero exit fails.
    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ISO9660Reader.Failure(description: "\(arguments) exited \(process.terminationStatus): \(text)")
        }
        return text
    }
    #endif
}
