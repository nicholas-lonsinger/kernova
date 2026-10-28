#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaAgentSimulation
import KernovaWire
import Testing

/// The golden transcripts, read from the source tree beside this file.
enum TranscriptFiles {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Transcripts")
    static let frozen = root.appendingPathComponent("frozen")
    static let current = root.appendingPathComponent("current")
    static let manifest = frozen.appendingPathComponent("frozen.sha256")

    /// Every frozen file the exchanges define: `Fnnh` with the host pinned, `Fnnp` the peer.
    static var frozenNames: [String] {
        Exchange.frozen.flatMap { exchange in
            exchange.pinnable.map { "\(exchange.id)\($0 == .host ? "h" : "p").transcript" }
        }
    }

    static func exchange(for name: String) -> (Exchange, SimSide)? {
        let pinned: SimSide = name.dropFirst(3).hasPrefix("h") ? .host : .peer
        let id = String(name.prefix(3))
        return Exchange.frozen.first { $0.id == id && $0.pinnable.contains(pinned) }.map { ($0, pinned) }
    }

    static func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }
}

@Suite("Golden transcripts")
struct TranscriptTests {
    /// Records any transcript not yet on disk — a frozen file is never rewritten —
    /// and the manifest when it is missing, and fails the run when it wrote
    /// anything, so a recording is always a deliberate commit.
    @Test("Every transcript exists; a missing one is recorded")
    func record() throws {
        try FileManager.default.createDirectory(at: TranscriptFiles.frozen, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: TranscriptFiles.current, withIntermediateDirectories: true)
        var recorded: [String] = []
        for name in TranscriptFiles.frozenNames {
            let url = TranscriptFiles.frozen.appendingPathComponent(name)
            guard TranscriptFiles.read(url) == nil,
                let (exchange, pinned) = TranscriptFiles.exchange(for: name),
                let duet = Duet(exchange)
            else { continue }
            duet.run()
            guard duet.failures.isEmpty else {
                Issue.record("\(name) not recorded: \(duet.failures.joined(separator: "; "))")
                continue
            }
            try Data(duet.render(pinned: pinned, fileID: String(name.prefix(4))).utf8).write(to: url)
            recorded.append(name)
        }
        if TranscriptFiles.read(TranscriptFiles.manifest) == nil {
            var manifest = ""
            for name in TranscriptFiles.frozenNames.sorted() {
                let data = try Data(contentsOf: TranscriptFiles.frozen.appendingPathComponent(name))
                manifest += "\(SHA256.hex(data))  \(name)\n"
            }
            try Data(manifest.utf8).write(to: TranscriptFiles.manifest)
            recorded.append("frozen.sha256")
        }
        for exchange in Exchange.current {
            let url = TranscriptFiles.current.appendingPathComponent("\(exchange.id).transcript")
            guard TranscriptFiles.read(url) == nil, let duet = Duet(exchange) else { continue }
            duet.run()
            guard duet.failures.isEmpty else {
                Issue.record("\(exchange.id) not recorded: \(duet.failures.joined(separator: "; "))")
                continue
            }
            try Data(duet.renderDuet().utf8).write(to: url)
            recorded.append(url.lastPathComponent)
        }
        #expect(recorded.isEmpty, "recorded \(recorded); review and commit them")
    }

    @Test("The manifest names every frozen transcript with its SHA-256, so an edit fails")
    func manifest() throws {
        let text = try #require(TranscriptFiles.read(TranscriptFiles.manifest), "frozen.sha256 is missing")
        var listed: [String] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            try #require(parts.count == 2, "malformed manifest line \(line)")
            let name = String(parts[1])
            listed.append(name)
            let data = try #require(
                try? Data(contentsOf: TranscriptFiles.frozen.appendingPathComponent(name)), "\(name) is missing")
            #expect(SHA256.hex(data) == String(parts[0]), "\(name) changed")
        }
        #expect(listed.sorted() == TranscriptFiles.frozenNames.sorted())
    }

    @Test("Each frozen transcript replays solo against the current other role", arguments: TranscriptFiles.frozenNames)
    func replay(_ name: String) throws {
        let text = try #require(
            TranscriptFiles.read(TranscriptFiles.frozen.appendingPathComponent(name)), "\(name) is missing")
        let transcript = try Transcript(parsing: text)
        let replay = try SoloReplay(transcript)
        replay.run()
        #expect(replay.failures.isEmpty, "\(name): \(replay.failures.joined(separator: "\n"))")
    }

    /// Pinned input past this many bytes is cut at every 4 KiB boundary instead of every byte.
    static let everyByteLimit = 64 << 10

    @Test("The pinned side's input cut at every byte offset ends cleanly", arguments: TranscriptFiles.frozenNames)
    func cuts(_ name: String) throws {
        let text = try #require(
            TranscriptFiles.read(TranscriptFiles.frozen.appendingPathComponent(name)), "\(name) is missing")
        let transcript = try Transcript(parsing: text)
        let total = transcript.pinnedBytes.reduce(0) { $0 + $1.bytes.count }
        let step = total > Self.everyByteLimit ? 4096 : 1
        for offset in stride(from: 0, through: total, by: step) {
            let replay = try SoloReplay(transcript)
            replay.runCut(at: offset)
            if !replay.failures.isEmpty {
                Issue.record("\(name) cut at \(offset): \(replay.failures.joined(separator: "; "))")
                return
            }
        }
    }

    @Test("Each current transcript replays duet, byte for byte", arguments: Exchange.current.map(\.id))
    func duet(_ id: String) throws {
        let exchange = try #require(Exchange.current.first { $0.id == id })
        let expected = try #require(
            TranscriptFiles.read(TranscriptFiles.current.appendingPathComponent("\(id).transcript")), "\(id) is missing"
        )
        let duet = try #require(Duet(exchange))
        duet.run()
        #expect(duet.failures.isEmpty, "\(duet.failures)")
        #expect(duet.renderDuet() == expected)
    }

    @Test("Only the update pull's frozen file is cut at 4 KiB boundaries; every other is cut at every byte")
    func cutStrides() throws {
        for name in TranscriptFiles.frozenNames {
            let text = try #require(TranscriptFiles.read(TranscriptFiles.frozen.appendingPathComponent(name)))
            let total = try Transcript(parsing: text).pinnedBytes.reduce(0) { $0 + $1.bytes.count }
            #expect((total > Self.everyByteLimit) == (name == "F09h.transcript"), "\(name): \(total) pinned bytes")
        }
    }

    @Test("F09 pins the STAGED result: the peer's END after its install, and the host's result event")
    func updateResultPinned() throws {
        let host = try #require(TranscriptFiles.read(TranscriptFiles.frozen.appendingPathComponent("F09h.transcript")))
        let peer = try #require(TranscriptFiles.read(TranscriptFiles.frozen.appendingPathComponent("F09p.transcript")))
        #expect(host.contains("expect  p>h s=3 END result.kind=1 result.code=0"))
        #expect(peer.contains("ev      host update result kind=1 code=0"))
    }

    /// `name`'s frozen text with the first line containing `fragment` removed or replaced.
    static func edited(_ name: String, _ fragment: String, with replacement: String? = nil) throws -> String {
        let text = try #require(TranscriptFiles.read(TranscriptFiles.frozen.appendingPathComponent(name)))
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let index = try #require(lines.firstIndex { $0.contains(fragment) }, "\(name) has no `\(fragment)`")
        if let replacement { lines[index] = replacement } else { lines.remove(at: index) }
        return lines.joined(separator: "\n")
    }

    static func replayFailures(_ text: String) throws -> [String] {
        let replay = try SoloReplay(Transcript(parsing: text))
        replay.run()
        return replay.failures
    }

    @Test("A strict frame the transcript does not expect fails the replay; an unexpected tolerant snapshot does not")
    func strictAndTolerant() throws {
        // F05p's current host sends the power request's END; without its expect line it is left over.
        let missingEnd = try Self.replayFailures(Self.edited("F05p.transcript", "s=2 END"))
        #expect(missingEnd.contains { $0.contains("does not expect") }, "\(missingEnd)")
        // The host's PolicyUpdate is a tolerant snapshot: a transcript without it still replays.
        #expect(try Self.replayFailures(Self.edited("F05p.transcript", "MSG policy")).isEmpty)
        // A strict frame expected where the current side sends another fails at once.
        let wrong = try Self.replayFailures(
            Self.edited(
                "F05p.transcript", "s=2 OPEN",
                with: "t=1000   expect  h>p s=2 OPEN kind=POWER_REQUEST body.action=2 body.acceptance_deadline_ms=0"))
        #expect(wrong.contains { $0.contains("produced `s=2 OPEN") }, "\(wrong)")
    }

    @Test("An event the transcript does not name fails the replay")
    func strictEvents() throws {
        let failures = try Self.replayFailures(Self.edited("F05p.transcript", "ev      host power"))
        #expect(failures.contains { $0.contains("event") }, "\(failures)")
    }
}

/// SHA-256 (FIPS 180-4), for the manifest on every platform.
enum SHA256 {
    private static let k: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    static func hex(_ data: Data) -> String {
        FrozenFields.hex(digest(data))
    }

    static func digest(_ data: Data) -> Data {
        var h: [UInt32] = [
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
        ]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for index in 0..<16 {
                let base = chunk + index * 4
                w[index] =
                    UInt32(message[base]) << 24 | UInt32(message[base + 1]) << 16 | UInt32(message[base + 2]) << 8
                    | UInt32(message[base + 3])
            }
            for index in 16..<64 {
                let s0 = rotate(w[index - 15], 7) ^ rotate(w[index - 15], 18) ^ (w[index - 15] >> 3)
                let s1 = rotate(w[index - 2], 17) ^ rotate(w[index - 2], 19) ^ (w[index - 2] >> 10)
                w[index] = w[index - 16] &+ s0 &+ w[index - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for index in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choice = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ choice &+ k[index] &+ w[index]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ temp1, c, b, a, temp1 &+ temp2)
            }
            h[0] &+= a
            h[1] &+= b
            h[2] &+= c
            h[3] &+= d
            h[4] &+= e
            h[5] &+= f
            h[6] &+= g
            h[7] &+= hh
        }
        var out = Data()
        for word in h {
            out.append(contentsOf: [
                UInt8(word >> 24), UInt8(word >> 16 & 0xFF), UInt8(word >> 8 & 0xFF), UInt8(word & 0xFF),
            ])
        }
        return out
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
        value >> count | value << (32 - count)
    }
}

@Suite("SHA-256")
struct SHA256Tests {
    @Test("Known vectors")
    func vectors() {
        #expect(SHA256.hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256.hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(
            SHA256.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }
}
