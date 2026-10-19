import Foundation
import KernovaTestSupport
import OSLog
import Testing

@testable import KernovaLogging

@Suite("LogMessage segments and the local record they emit as", .caseScoped)
struct LogMessageTests {
    private struct Point {
        let x: Int
    }

    private func segments(_ message: LogMessage) -> [LogSegment] {
        message.segments
    }

    private func pub(_ text: String) -> LogSegment {
        LogSegment(text: text, isPrivate: false)
    }

    private func priv(_ text: String) -> LogSegment {
        LogSegment(text: text, isPrivate: true)
    }

    // MARK: - Default privacy

    @Test("Integers, floating-point values and Booleans default to public")
    func numericAndBooleanDefaultToPublic() {
        let count = 7
        let byte = UInt8(3)
        let ratio = 2.5
        let scale = Float(1.5)
        let flag = true
        #expect(segments("\(count)") == [pub("7")])
        #expect(segments("\(byte)") == [pub("3")])
        #expect(segments("\(ratio)") == [pub("2.5")])
        #expect(segments("\(scale)") == [pub("1.5")])
        #expect(segments("\(flag)") == [pub("true")])
    }

    @Test("Strings and other values default to private")
    func stringsAndObjectsDefaultToPrivate() {
        let name = "alice"
        let substring = name.prefix(3)
        let point = Point(x: 1)
        #expect(segments("\(name)") == [priv("alice")])
        #expect(segments("\(substring)") == [priv("ali")])
        #expect(segments("\(point)") == [priv("Point(x: 1)")])
    }

    @Test("An explicit privacy overrides the default in both directions")
    func explicitPrivacyWins() {
        let name = "alice"
        let point = Point(x: 1)
        let count = 7
        let flag = false
        #expect(segments("\(name, privacy: .public)") == [pub("alice")])
        #expect(segments("\(point, privacy: .public)") == [pub("Point(x: 1)")])
        #expect(segments("\(count, privacy: .private)") == [priv("7")])
        #expect(segments("\(flag, privacy: .private)") == [priv("false")])
    }

    // MARK: - Literal text

    @Test("Literal text between interpolations is one public segment, and an empty run adds none")
    func literalRuns() {
        let a = 1
        let b = "x"
        #expect(
            segments("a \(a, privacy: .public) b \(b, privacy: .private)")
                == [pub("a "), pub("1"), pub(" b "), priv("x")])
        #expect(segments("\(a)\(b)") == [pub("1"), priv("x")])
        #expect(segments("") == [])
        #expect(segments("started") == [pub("started")])
    }

    @Test("Escapes decode to the characters they spell")
    func escapes() {
        let n = 1
        #expect(segments("tab\there \"q\" \u{2014}\n\(n)") == [pub("tab\there \"q\" —\n"), pub("1")])
    }

    @Test("A raw literal keeps its backslashes and quotes, and interpolates with its delimiter")
    func rawLiteral() {
        let name = "bob"
        #expect(
            segments(#"say "hi"\n\#(name, privacy: .public)"#)
                == [pub(#"say "hi"\n"#), pub("bob")])
    }

    @Test("A multi-line literal strips its indentation and honors line continuation")
    func multiLineLiteral() {
        let a = 1
        let message: LogMessage = """
            first \(a, privacy: .public), \
            second
            third
            """
        #expect(message.segments == [pub("first "), pub("1"), pub(", second\nthird")])
    }

    @Test("init(segments:) carries its segments unchanged")
    func initFromSegments() {
        let given = [pub("[a/b] "), priv("secret"), pub("")]
        #expect(LogMessage(segments: given).segments == given)
    }

    // MARK: - Local record

    @Test("A message with no private segment emits as one public run")
    func localRecordAllPublic() {
        #expect(LocalLogRecord(segments: []) == .noPrivate(""))
        #expect(LocalLogRecord(segments: [pub("saw "), pub("3"), pub(" items")]) == .noPrivate("saw 3 items"))
    }

    @Test("Adjacent segments of one privacy merge into one run, and empty segments drop out")
    func localRecordMergesRuns() {
        #expect(
            LocalLogRecord(segments: [pub("copied "), priv("/a/"), priv("b.txt"), pub(""), pub(" to "), priv("vm")])
                == .twoPrivate("copied ", "/a/b.txt", " to ", "vm", ""))
        #expect(LocalLogRecord(segments: [priv("x"), priv(""), priv("y")]) == .onePrivate("", "xy", ""))
    }

    @Test("Up to three private runs each get their own argument")
    func localRecordThreePrivateRuns() {
        #expect(
            LocalLogRecord(segments: [pub("a"), priv("1"), pub("b"), priv("2"), pub("c"), priv("3"), pub("d")])
                == .threePrivate("a", "1", "b", "2", "c", "3", "d"))
    }

    @Test("The fourth and later private runs fold, with the text between, into the third")
    func localRecordFoldsBeyondThree() {
        #expect(
            LocalLogRecord(segments: [
                priv("1"), pub("a"), priv("2"), pub("b"), priv("3"), pub("c"), priv("4"), pub("d"), priv("5"),
                pub("e"),
            ]) == .threePrivate("", "1", "a", "2", "b", "3c4d5", "e"))
    }

    // MARK: - Emitted record

    /// A message whose emitted record the log store is read back for.
    enum EmittedShape: String, Codable, CaseIterable, Sendable {
        case noPrivate, onePrivate, twoPrivate, threePrivate

        var message: LogMessage {
            switch self {
            case .noPrivate:
                let count = 3
                return "saw \(count, privacy: .public) items"
            case .onePrivate:
                return "opened \("/a/b.txt", privacy: .private) for \("vm", privacy: .public)"
            case .twoPrivate:
                return "a\("1", privacy: .private)b\("2", privacy: .private)c"
            case .threePrivate:
                return "a\("1", privacy: .private)b\("2", privacy: .private)c\("3", privacy: .private)d"
            }
        }

        var formatString: String {
            switch self {
            case .noPrivate: "%{public}s"
            case .onePrivate: "%{public}s%{private}s%{public}s"
            case .twoPrivate: "%{public}s%{private}s%{public}s%{private}s%{public}s"
            case .threePrivate: "%{public}s%{private}s%{public}s%{private}s%{public}s%{private}s%{public}s"
            }
        }

        var runs: [LogSegment] {
            let pub = { LogSegment(text: $0, isPrivate: false) }
            let priv = { LogSegment(text: $0, isPrivate: true) }
            return switch self {
            case .noPrivate: [pub("saw 3 items")]
            case .onePrivate: [pub("opened "), priv("/a/b.txt"), pub(" for vm")]
            case .twoPrivate: [pub("a"), priv("1"), pub("b"), priv("2"), pub("c")]
            case .threePrivate: [pub("a"), priv("1"), pub("b"), priv("2"), pub("c"), priv("3"), pub("d")]
            }
        }
    }

    /// One record as this process's log store returns it.
    struct EmittedEntry: Codable {
        let formatString: String
        let arguments: [String?]

        /// Logs `shape` at `.notice` through a sink-less logger, then writes
        /// every record of its category in this process's store to standard
        /// output as JSON.
        static func emitAndReadBack(_ shape: EmittedShape) throws {
            let subsystem = "app.kernova.tests"
            let category = "Emit-\(shape.rawValue)"
            KernovaLogger(subsystem: subsystem, category: category).log(.notice, shape.message)
            let entries = try OSLogStore(scope: .currentProcessIdentifier)
                .getEntries(matching: NSPredicate(format: "subsystem == %@ AND category == %@", subsystem, category))
                .compactMap { $0 as? OSLogEntryLog }
                .map {
                    EmittedEntry(formatString: $0.formatString, arguments: $0.components.map(\.argumentStringValue))
                }
            FileHandle.standardOutput.write(try JSONEncoder().encode(entries))
        }
    }

    /// Whether `arguments` lead with `runs` in order: a public run as its
    /// text, a private run redacted or — under the system's private-data
    /// setting — as its text.
    private func carries(_ arguments: [String?], _ runs: [LogSegment]) -> Bool {
        guard arguments.count >= runs.count else { return false }
        return zip(runs, arguments).allSatisfy { run, argument in
            run.isPrivate ? (argument == nil || argument == run.text) : argument == run.text
        }
    }

    // The store promises neither one copy of a record nor any, and a
    // `.currentProcessIdentifier` read ignores its position and scans the
    // process's whole log (https://developer.apple.com/forums/thread/705868),
    // so each read runs in a fresh child and every copy it returns must carry
    // the shape.
    @Test("Each private run emits as its own private argument between public ones", arguments: EmittedShape.allCases)
    func emitsItsPrivacy(_ shape: EmittedShape) async throws {
        let exit = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            [shape = shape as EmittedShape] in
            try EmittedEntry.emitAndReadBack(shape)
        }
        let output = try #require(exit).standardOutputContent
        let entries = try JSONDecoder().decode([EmittedEntry].self, from: Data(output))
        #expect(!entries.isEmpty)
        for entry in entries {
            #expect(entry.formatString == shape.formatString)
            #expect(carries(entry.arguments, shape.runs))
        }
    }
}
