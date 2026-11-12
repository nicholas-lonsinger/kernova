import Foundation
import KernovaCommandModel
import KernovaConsole
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// A notice the app attaches to an answer, as the tool writes it: on standard
/// error, after the answer, leaving standard output as it would be without it.
@Suite("CLI notices", .caseScoped)
struct CLINoticeTests {
    /// One write, to the stream it went to.
    private enum Line: Equatable {
        case out(String)
        case err(String)
    }

    private let settings = [ConfigurationEntry(key: "cpus", value: "4")]
    private let alpha = VMSummary(
        id: UUID(), name: "Alpha Pool", status: "stopped", ipAddress: .unavailable,
        heldByAnotherCopy: false)
    private let baseline = SnapshotSummary(
        id: UUID(), name: "Clean install", notes: "", kind: "cold", createdAt: Date(),
        isCurrent: true, isEphemeralBaseline: true)

    /// The lines written, in order; locked because the streams are `@Sendable`.
    private final class Written: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [Line] = []

        func append(_ line: Line) { lock.withLock { lines.append(line) } }
        var all: [Line] { lock.withLock { lines } }
    }

    private var notice: VMCommandNotice { .ephemeralRevert(vm: alpha, baseline: baseline) }

    /// Runs `kernova set Alpha cpus=4` plus `flags` against a double answering
    /// with `notices`, answering the lines it wrote, in order.
    private func set(flags: [String], notices: [VMCommandNotice]) throws -> [Line] {
        let command = try #require(
            try KernovaCommand.parseAsRoot(["set", "Alpha", "cpus=4"] + flags) as? KernovaCommand.Set)
        let listener = try TestCommandSocket()
        defer { listener.close() }
        let client = try VMCommandClient(socketPath: listener.path)
        client.waitForFrames(upTo: testWaitBackstop)
        listener.serve([[VMCommandResponse(result: .configuration(settings), notices: notices)]])

        let written = Written()
        let streams = Console.Streams(
            out: { written.append(.out($0)) }, err: { written.append(.err($0)) })
        try Console.$streams.withValue(streams) {
            try client.answer(try command.verb()) {
                try ConfigurationOutput.write($0, options: command.options)
            }
        }
        return written.all
    }

    @Test(
        "A notice leaves standard output as it was and follows it on standard error",
        arguments: [[], ["--quiet"], ["--format", "json"]])
    func noticeFollowsTheAnswerOnStandardError(flags: [String]) throws {
        let plain = try set(flags: flags, notices: [])
        let noticed = try set(flags: flags, notices: [notice])

        #expect(!plain.isEmpty)
        #expect(plain.allSatisfy { if case .out = $0 { true } else { false } })
        #expect(noticed == plain + [.err(CommandLineSpelling.message(for: notice) + "\n")])
    }

    @Test("The notice names the VM and baseline and spells both command lines for a shell")
    func noticeSpellsItsCommandLines() {
        #expect(
            CommandLineSpelling.message(for: notice)
                == "Ephemeral Mode is on for \u{201C}Alpha Pool\u{201D}: this change goes back to "
                + "\u{201C}Clean install\u{201D} at the next shutdown. To keep it, take a snapshot "
                + "(kernova snapshot take 'Alpha Pool') and choose it as the baseline "
                + "(kernova set 'Alpha Pool' ephemeral.baseline=<snapshot>).")
    }
}
