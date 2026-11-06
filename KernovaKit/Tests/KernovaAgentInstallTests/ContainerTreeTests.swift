#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import KernovaAgentCore
import KernovaDigest
import KernovaPortableTestSupport
import KernovaWire
import Testing

@testable import KernovaAgentInstall

/// A small tree shaped like an app bundle, with fixed modes: a directory, files, an executable, a symlink, and a
/// file of zeros past one chunk.
final class BundleFixture {
    let directory: PortableScratchDirectory
    /// The bundle's path.
    let path: String

    /// Every entry below the bundle and what it is: `d0755`, `f0644:<SHA-256>`, `l<target>`.
    static let expected: [String: String] = [
        "Contents": "d0755",
        "Contents/Info.plist": "f0644:" + hex(Array(info.utf8)),
        "Contents/MacOS": "d0755",
        "Contents/MacOS/agent": "f0755:" + hex(Array(script.utf8)),
        "Contents/Frameworks": "d0700",
        "Contents/Frameworks/Current": "lA",
        "Contents/Resources": "d0755",
        "Contents/Resources/zeros": "f0600:" + hex([UInt8](repeating: 0, count: zeroCount)),
    ]

    static let info = "<plist><dict><key>CFBundleIdentifier</key><string>app.kernova.test</string></dict></plist>\n"
    static let script = "#!/bin/sh\nexit 0\n"
    /// More than one chunk, so the zeros cross a chunk boundary as one zero run.
    static let zeroCount = 300_000

    init() throws {
        directory = try PortableScratchDirectory(prefix: "kernova-bundle")
        path = directory.path + "/Item.app"
        let manager = FileManager.default
        for directory in ["", "/Contents", "/Contents/MacOS", "/Contents/Frameworks", "/Contents/Resources"] {
            try manager.createDirectory(atPath: path + directory, withIntermediateDirectories: false)
        }
        try write("/Contents/Info.plist", Data(Self.info.utf8), mode: 0o644)
        try write("/Contents/MacOS/agent", Data(Self.script.utf8), mode: 0o755)
        try write("/Contents/Resources/zeros", Data(count: Self.zeroCount), mode: 0o600)
        try manager.createSymbolicLink(atPath: path + "/Contents/Frameworks/Current", withDestinationPath: "A")
        for (directory, mode) in [
            ("", 0o755), ("/Contents", 0o755), ("/Contents/MacOS", 0o755), ("/Contents/Frameworks", 0o700),
            ("/Contents/Resources", 0o755),
        ] {
            #expect(chmod(path + directory, mode_t(mode)) == 0)
        }
    }

    private func write(_ name: String, _ data: Data, mode: mode_t) throws {
        try data.write(to: URL(fileURLWithPath: path + name))
        #expect(chmod(path + name, mode) == 0)
    }

    /// The payload the packer makes of the bundle.
    func pack() throws -> Data {
        var payload = Data()
        try UpdatePayloadPacker.pack(directoryAt: path) { payload.append($0) }
        return payload
    }

    /// Every entry below `item`, described as ``expected`` describes them.
    static func describe(_ item: String) throws -> [String: String] {
        var entries: [String: String] = [:]
        var pending = try FileManager.default.contentsOfDirectory(atPath: item)
        while let name = pending.popLast() {
            var info = stat()
            guard lstat(item + "/" + name, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
            let mode = "0" + String(info.st_mode & 0o7777, radix: 8)
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                entries[name] = "d" + mode
                pending += try FileManager.default.contentsOfDirectory(atPath: item + "/" + name).map {
                    name + "/" + $0
                }
            case S_IFREG:
                let bytes = Array(try Data(contentsOf: URL(fileURLWithPath: item + "/" + name)))
                entries[name] = "f" + mode + ":" + hex(bytes)
            case S_IFLNK:
                entries[name] = "l" + (try FileManager.default.destinationOfSymbolicLink(atPath: item + "/" + name))
            default:
                entries[name] = "?"
            }
        }
        return entries
    }

    static func hex(_ bytes: [UInt8]) -> String {
        lowercaseHex(Data(SHA256.hash(bytes)))
    }
}

@Suite("The update profile's packer and lander")
struct ContainerTreeTests {
    /// The payload the packer must reproduce byte for byte: the update profile, frozen.
    static let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Golden/update-profile.payload")

    static let itemName = "Item.app"

    /// The system of a lander that only installs: an install runs neither check.
    static let installOnly = ContainerTreeLander.System(
        selfTest: { _ in
            Issue.record("an install ran the self-test"); return .passed
        },
        launchRefusal: { _ in
            Issue.record("an install ran the launch check"); return nil
        })

    /// Records the golden payload when it is missing — a frozen file is never rewritten — and fails the run
    /// that does, so a recording is always a deliberate commit.
    @Test("The packer reproduces the golden update-profile payload byte for byte")
    func golden() throws {
        let payload = try BundleFixture().pack()
        guard let frozen = FileManager.default.contents(atPath: Self.golden.path) else {
            try FileManager.default.createDirectory(
                at: Self.golden.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: Self.golden)
            Issue.record("Recorded \(Self.golden.lastPathComponent); commit it")
            return
        }
        #expect(payload == frozen)
    }

    @Test("The golden payload holds only the update profile's records: header, chunk, zero run and end")
    func profileRecords() throws {
        let frozen = try #require(FileManager.default.contents(atPath: Self.golden.path))
        var kinds: [UInt8] = []
        var offset = 0
        let bytes = Array(frozen)
        while offset < bytes.count {
            let length =
                Int(bytes[offset + 1]) | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]) << 16
                | Int(bytes[offset + 4]) << 24
            kinds.append(bytes[offset])
            offset += 9 + length
        }
        #expect(offset == bytes.count)
        #expect(Set(kinds).isSubset(of: [1, 2, 4, 5]))
        #expect(kinds.first == 1 && kinds.last == 5 && kinds.contains(4))
    }

    @Test("An update lands the golden payload as the item in the spare slot, once its self-test passes")
    func updateLandsGolden() throws {
        let frozen = try #require(FileManager.default.contents(atPath: Self.golden.path))
        let fixture = try SlotFixture()
        let ran = Inbox<String>()
        let checked = Inbox<String>()
        let lander = ContainerTreeLander(
            itemName: Self.itemName, selfTestExecutable: "Contents/MacOS/agent",
            system: .init(
                selfTest: {
                    ran.put($0); return .passed
                },
                launchRefusal: {
                    checked.put($0); return nil
                }))
        let landing = try lander.beginUpdate(in: "b", of: fixture.slotRoot())
        for start in stride(from: 0, to: frozen.count, by: 4096) {
            let piece = frozen[start..<min(start + 4096, frozen.count)]
            try piece.withUnsafeBytes { try landing.write($0) }
        }
        try landing.publish()
        #expect(try checked.next() == fixture.root + "/slots/b/" + Self.itemName)
        #expect(try ran.next() == fixture.root + "/slots/b/" + Self.itemName + "/Contents/MacOS/agent")
        #expect(try BundleFixture.describe(fixture.root + "/slots/b/" + Self.itemName) == BundleFixture.expected)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root + "/slots/b") == [Self.itemName])
    }

    @Test("An update replaces the item the spare slot held, and a refused one puts it back")
    func updateReplacesAndRestores() throws {
        let frozen = try #require(FileManager.default.contents(atPath: Self.golden.path))
        let fixture = try SlotFixture()
        let old = fixture.root + "/slots/b/" + Self.itemName
        try FileManager.default.createDirectory(atPath: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: URL(fileURLWithPath: old + "/marker"))

        let refusing = ContainerTreeLander(
            itemName: Self.itemName, selfTestExecutable: "Contents/MacOS/agent",
            system: .init(selfTest: { _ in .exited(1) }, launchRefusal: { _ in nil }))
        let refused = try refusing.beginUpdate(in: "b", of: fixture.slotRoot())
        try frozen.withUnsafeBytes { try refused.write($0) }
        #expect {
            try refused.publish()
        } throws: { error in
            (error as? PayloadRefusal)?.rejectsPayload == true
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root + "/slots/b") == [Self.itemName])
        #expect(FileManager.default.contents(atPath: old + "/marker") == Data("old".utf8))

        let passing = ContainerTreeLander(
            itemName: Self.itemName, selfTestExecutable: "Contents/MacOS/agent",
            system: .init(selfTest: { _ in .passed }, launchRefusal: { _ in nil }))
        let landing = try passing.beginUpdate(in: "b", of: fixture.slotRoot())
        try frozen.withUnsafeBytes { try landing.write($0) }
        try landing.publish()
        #expect(try BundleFixture.describe(old) == BundleFixture.expected)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root + "/slots/b") == [Self.itemName])
    }

    @Test("An update the OS would not launch is refused with the check's own refusal before any self-test runs")
    func launchRefused() throws {
        let frozen = try #require(FileManager.default.contents(atPath: Self.golden.path))
        let fixture = try SlotFixture()
        let old = fixture.root + "/slots/b/" + Self.itemName
        try FileManager.default.createDirectory(atPath: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: URL(fileURLWithPath: old + "/marker"))
        let refusal = PayloadRefusal(.updateLaunchRefused, "fails the running agent's designated requirement")
        let lander = ContainerTreeLander(
            itemName: Self.itemName, selfTestExecutable: "Contents/MacOS/agent",
            system: .init(
                selfTest: { _ in
                    Issue.record("the self-test ran"); return .passed
                },
                launchRefusal: { _ in refusal }))
        let landing = try lander.beginUpdate(in: "b", of: fixture.slotRoot())
        try frozen.withUnsafeBytes { try landing.write($0) }
        #expect {
            try landing.publish()
        } throws: { error in
            let thrown = error as? PayloadRefusal
            return thrown?.code == .updateLaunchRefused && thrown?.rejectsPayload == true
                && thrown?.detail == refusal.detail
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root + "/slots/b") == [Self.itemName])
        #expect(FileManager.default.contents(atPath: old + "/marker") == Data("old".utf8))
    }

    @Test("A discarded update and a truncated one leave the slot as it was")
    func discardAndTruncation() throws {
        let frozen = try #require(FileManager.default.contents(atPath: Self.golden.path))
        let fixture = try SlotFixture()
        let lander = ContainerTreeLander(
            itemName: Self.itemName, selfTestExecutable: "Contents/MacOS/agent",
            system: .init(selfTest: { _ in .passed }, launchRefusal: { _ in nil }))

        let discarded = try lander.beginUpdate(in: "b", of: fixture.slotRoot())
        try frozen.prefix(frozen.count / 2).withUnsafeBytes { try discarded.write($0) }
        discarded.discard()
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root + "/slots/b").isEmpty)

        let truncated = try lander.beginUpdate(in: "b", of: fixture.slotRoot())
        try frozen.prefix(frozen.count - 3).withUnsafeBytes { try truncated.write($0) }
        #expect {
            try truncated.publish()
        } throws: { error in
            (error as? PayloadRefusal)?.rejectsPayload == true
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root + "/slots/b").isEmpty)
    }

    @Test("An install lands the payload as the item in the slot current does not name and records its SHA-256")
    func installLandsGolden() throws {
        let frozen = try #require(FileManager.default.contents(atPath: Self.golden.path))
        let scratch = try PortableScratchDirectory(prefix: "kernova-container-install")
        let payload = scratch.path + "/agent.payload"
        try frozen.write(to: URL(fileURLWithPath: payload))
        let root = InstallRoot(path: "/agent")
        let stage = scratch.path + "/stage"
        try FileManager.default.createDirectory(atPath: stage, withIntermediateDirectories: false)
        let lander = ContainerTreeLander(
            itemName: Self.itemName, selfTestExecutable: "Contents/MacOS/agent", system: Self.installOnly)
        let installer = Installer(
            stagingRoot: stage, runsCommands: false, payloadSource: .file(payload), lander: lander,
            versionLabel: "9.9 (99)", account: nil)
        let definitions = TestDefinitions(root: root, directory: "/services")
        for slot in ["a", "b", "a"] {
            try installer.run(.install(root: root, payloadName: Self.itemName, definitions: definitions))
            let directory = stage + "/agent/slots/" + slot
            #expect(try BundleFixture.describe(directory + "/" + Self.itemName) == BundleFixture.expected)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory) == [Self.itemName])
            let state = try InstallState.decoded(
                Array(try Data(contentsOf: URL(fileURLWithPath: stage + "/agent/state.json"))))
            #expect(state.active == slot)
            #expect(state.slots[slot]?.payloadSHA256 == lowercaseHex(Data(SHA256.hash(Array(frozen)))))
        }
    }

    @Test("An install from a directory packs it as it lands, recording the SHA-256 of the packed tree")
    func installPacksDirectory() throws {
        let frozen = try #require(FileManager.default.contents(atPath: Self.golden.path))
        let bundle = try BundleFixture()
        let scratch = try PortableScratchDirectory(prefix: "kernova-container-install")
        let root = InstallRoot(path: "/agent")
        let stage = scratch.path + "/stage"
        try FileManager.default.createDirectory(atPath: stage, withIntermediateDirectories: false)
        let installer = Installer(
            stagingRoot: stage, runsCommands: false, payloadSource: .packedDirectory(bundle.path),
            lander: ContainerTreeLander(
                itemName: Self.itemName, selfTestExecutable: "Contents/MacOS/agent", system: Self.installOnly),
            versionLabel: "9.9 (99)", account: nil)
        let definitions = TestDefinitions(root: root, directory: "/services")
        try installer.run(.install(root: root, payloadName: Self.itemName, definitions: definitions))
        #expect(try BundleFixture.describe(stage + "/agent/slots/a/" + Self.itemName) == BundleFixture.expected)
        let state = try InstallState.decoded(
            Array(try Data(contentsOf: URL(fileURLWithPath: stage + "/agent/state.json"))))
        #expect(state.slots["a"]?.payloadSHA256 == lowercaseHex(Data(SHA256.hash(Array(frozen)))))
    }
}
#endif
