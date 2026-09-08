import Foundation
import KernovaKit

/// What `kernova` exits with, and the one place any refusal is turned into a
/// number.
///
/// A script's whole view of what happened, so every code names one kind of
/// outcome and every refusal maps here rather than at the call site that
/// raised it.
public enum CLIExitCode: Int32, Sendable, Hashable, CaseIterable {
    case success = 0
    case operationFailed = 1
    case usage = 2
    case notFound = 3
    case ambiguous = 4
    case refusedByState = 5
    case busy = 6
    case timedOut = 7
    case authorizationRefused = 8
    case unavailable = 9

    /// What this code means, in the words `kernova --help` prints.
    ///
    /// A `switch` rather than a table, so a code added without a line to
    /// describe it does not compile.
    public var summary: String {
        switch self {
        case .success: "The verb ran and did what was asked."
        case .operationFailed: "The verb ran and did not complete."
        case .usage: "The command line could not be parsed, or an argument was not valid."
        case .notFound: "No VM answers to the selector."
        case .ambiguous: "More than one VM answers to the selector."
        case .refusedByState: "The VM's state, this build, or a missing consent refused the verb."
        case .busy: "The VM has work in flight the verb would race."
        case .timedOut: "A deadline expired before the state arrived."
        case .authorizationRefused: "The app would not accept this process as a peer."
        case .unavailable: "There is no app to talk to, or this build cannot talk to one."
        }
    }

    /// Every code and what it means, as the root command's help prints it.
    static var contract: String {
        "Every verb exits with one of these codes:\n\n"
            + allCases.map { "  \($0.rawValue)  \($0.summary)" }.joined(separator: "\n")
    }

    /// The code a verb's own refusal exits with.
    public init(_ failure: CommandErrorDTO) {
        switch failure {
        case .notFound: self = .notFound
        case .ambiguous: self = .ambiguous
        case .invalidState, .unsupported, .conflict, .confirmationRequired: self = .refusedByState
        case .invalidArgument: self = .usage
        case .busy: self = .busy
        case .timedOut: self = .timedOut
        case .operationFailed: self = .operationFailed
        }
    }

    /// The code an envelope refusal exits with.
    ///
    /// A version mismatch is `unavailable`, not a usage error: the command was
    /// well-formed and the app on the other end is simply not one this tool can
    /// talk to.
    public init(_ refusal: VMCommandTransportRefusal) {
        switch refusal {
        case .authorizationRefused: self = .authorizationRefused
        case .unsupportedProtocolVersion, .undecodableRequest: self = .unavailable
        }
    }
}

/// A refusal on its way to `exit` — the message a user reads and the code a
/// script reads, carried together.
struct CLIFailure: Error, Sendable, Hashable {
    /// What the process exits with.
    let code: CLIExitCode
    /// What is written to standard error, empty when there is nothing to add.
    let message: String

    /// Names one outcome and what to say about it.
    init(_ code: CLIExitCode, _ message: String = "") {
        self.code = code
        self.message = message
    }
}
