import Foundation
import KernovaKit

/// What `kernova` exits with, and the one place any refusal is turned into a
/// number.
///
/// A script's whole view of what happened, so every code names one kind of
/// outcome and every refusal maps here rather than at the call site that
/// raised it.
public enum CLIExitCode: Int32, Sendable, Hashable, CaseIterable {
    /// The verb ran and did what was asked.
    case success = 0
    /// The verb ran and did not complete.
    case operationFailed = 1
    /// The command line could not be parsed, or an argument was not valid.
    case usage = 2
    /// No VM answers to the selector.
    case notFound = 3
    /// More than one VM answers to the selector.
    case ambiguous = 4
    /// The VM's state, this build, or a missing consent refused the verb.
    case refusedByState = 5
    /// The VM has work in flight the verb would race.
    case busy = 6
    /// A deadline expired before the state arrived.
    case timedOut = 7
    /// The app would not accept this process as a peer.
    case authorizationRefused = 8
    /// There is no app to talk to, or this build cannot talk to one.
    case unavailable = 9

    /// The code a verb's own refusal exits with.
    public init(_ failure: CommandErrorDTO) {
        switch failure {
        case .notFound: self = .notFound
        case .ambiguous: self = .ambiguous
        case .invalidState, .unsupported, .conflict, .confirmationRequired: self = .refusedByState
        case .busy: self = .busy
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
public struct CLIFailure: Error, Sendable, Hashable {
    /// What the process exits with.
    public let code: CLIExitCode
    /// What is written to standard error, empty when there is nothing to add.
    public let message: String

    /// Names one outcome and what to say about it.
    public init(_ code: CLIExitCode, _ message: String = "") {
        self.code = code
        self.message = message
    }
}
