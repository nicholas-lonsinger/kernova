import Foundation
import KernovaLogging
import KernovaTestSupport
import OSLog
import Testing

@Suite("The record a LogMessage emits to the unified log", .caseScoped)
struct LogMessageEmissionTests {
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

        /// Logs `shape` at `.notice` through a sink-less logger under a fresh
        /// category, then writes every record of that category in this
        /// process's store to standard output as JSON.
        static func emitAndReadBack(_ shape: EmittedShape) throws {
            let subsystem = "app.kernova.tests"
            let category = "Emit-\(shape.rawValue)-\(UUID().uuidString)"
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
