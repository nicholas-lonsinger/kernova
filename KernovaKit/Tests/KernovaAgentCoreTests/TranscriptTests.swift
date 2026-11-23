#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentSimulation
import KernovaPortableTestSupport
import Testing

/// The golden transcripts, read from the source tree beside this file.
enum TranscriptFiles {
    static let root = SourceTree.url("KernovaKit/Tests/KernovaAgentCoreTests/Transcripts")
    static let frozen = root.appendingPathComponent("frozen")

    /// Every frozen file the exchanges define: `Fnnh` with the host pinned, `Fnnp` the peer.
    static var frozenNames: [String] {
        Exchange.frozen.flatMap { exchange in
            exchange.pinnable.map { "\(exchange.id)\($0 == .host ? "h" : "p").transcript" }
        }
    }

    static func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }
}

@Suite("Golden transcripts")
struct TranscriptTests {
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
}
