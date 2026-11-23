#if os(Linux)
import Foundation
import KernovaPortableTestSupport
import Testing

@testable import KernovaISO9660

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

    /// xorriso, the reference reader on Linux CI, lists the names and modes, and extracts the bytes.
    @Test("xorriso lists the names and modes, and osirrox extracts the same bytes and modes")
    func xorrisoAgrees() async throws {
        let directory = try PortableScratchDirectory(prefix: "iso9660")
        let scratch = directory.url
        let iso = scratch.appending(path: "agent.iso")
        let entries = Self.entries()
        try Data(try Self.write(entries)).write(to: iso)

        let listing = try await Self.run(["xorriso", "-indev", iso.path, "-find", "/", "-type", "f", "-exec", "lsdl"])
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
        _ = try await Self.run(["xorriso", "-osirrox", "on", "-indev", iso.path, "-extract", "/", extracted.path])
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

    private struct RunFailure: Error, CustomStringConvertible {
        var description: String
    }

    /// Runs `arguments` from PATH and answers its standard output; a non-zero exit fails.
    private static func run(_ arguments: [String]) async throws -> String {
        let ran = try await ChildProcess(URL(filePath: "/usr/bin/env"), arguments).exit()
        let text = String(decoding: ran.output, as: UTF8.self)
        guard ran.status == 0 else {
            throw RunFailure(description: "\(arguments) exited \(ran.status): \(text)")
        }
        return text
    }
}
#endif
