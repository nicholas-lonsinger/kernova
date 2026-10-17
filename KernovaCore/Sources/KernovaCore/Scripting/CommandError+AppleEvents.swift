import CoreServices
import Foundation
import KernovaKit

extension CommandError {
    /// The Apple event error number a script reads this refusal as.
    ///
    /// Coarser than the partition ``CLIExitCode`` draws: AppleScript gives
    /// meaning to four numbers — an object that isn't there, a type it cannot
    /// use, a deadline, and everything the verb itself refused — and the
    /// refusals the tool tells apart by exit code fold into them.
    var appleEventErrorNumber: Int {
        switch self {
        case .notFound, .itemNotFound, .itemNotFoundOnHost, .ambiguous:
            Int(errAENoSuchObject)
        case .invalidArgument:
            Int(errAETypeError)
        case .timedOut:
            Int(errAETimeout)
        case .invalidState, .changeTakesStoppedVM, .stepRequired, .unsupported, .unsupportedByBuild,
            .conflict,
            .confirmationRequired, .guestAccountPasswordRequired, .busy,
            .heldByAnotherCopy,
            .terminating, .operationFailed, .filesKept:
            Int(errAEEventFailed)
        }
    }

    /// What the script reads back, in the same words every other door shows.
    ///
    /// A consent refusal gains the one thing a script can do about it, as the
    /// `kernova` tool's own refusal names `--yes`.
    var appleEventErrorString: String {
        switch self {
        case .confirmationRequired:
            return message + "\n\nAdd `with confirmation` to do it anyway."
        default:
            return message
        }
    }
}

extension NSScriptCommand {
    /// Records what the script reads back instead of a result.
    package func refuse(_ number: Int, _ message: String) {
        scriptErrorNumber = number
        scriptErrorString = message
    }

    /// Records the core's refusal, in the number and words a script reads it as.
    package func refuse(_ refusal: CommandError) {
        refuse(refusal.appleEventErrorNumber, refusal.appleEventErrorString)
    }
}
