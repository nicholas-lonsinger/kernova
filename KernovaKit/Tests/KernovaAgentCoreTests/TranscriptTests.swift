#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaAgentSimulation
import KernovaDigest
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
                manifest += "\(FrozenFields.hex(Data(SHA256.hash(data))))  \(name)\n"
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
            #expect(FrozenFields.hex(Data(SHA256.hash(data))) == String(parts[0]), "\(name) changed")
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
