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
        case .invalidState, .changeTakesStoppedVM, .unsupported, .unsupportedByBuild, .conflict,
            .confirmationRequired, .guestAccountPasswordRequired, .macAddressRemedyRequired, .busy,
            .heldByAnotherCopy,
            .terminating, .operationFailed, .filesKept:
            Int(errAEEventFailed)
        }
    }

    /// What the script reads back, in the same words every other door shows.
    ///
    /// A consent refusal gains the one thing a script can do about it, as the
    /// `kernova` tool's own refusal names `--yes` — but only where confirming
    /// performs the verb that was asked for. A stop a paused guest cannot
    /// receive is refused with the flag as readily as without it, and the
    /// core's own message is what names the stop methods that would work. A
    /// MAC address refusal names the parameter that takes each change it
    /// offers.
    var appleEventErrorString: String {
        switch self {
        case .confirmationRequired(let prompt) where VMConsentPolicy.isAnsweredByConfirming(prompt):
            return message + "\n\nAdd `with confirmation` to do it anyway."
        case .macAddressRemedyRequired(let prompt) where !prompt.offers.isEmpty:
            let terms = prompt.offers.map { "`resolving MAC conflict by \(VMScriptMACConflictRemedy($0.remedy).term)`" }
            let choices =
                terms.count > 1
                ? terms.dropLast().joined(separator: ", ") + " or " + terms[terms.count - 1]
                : terms.joined()
            return message + "\n\nAdd \(choices) to change \u{201C}\(prompt.vm.name)\u{201D}\u{2019}s network first."
        default:
            return message
        }
    }
}

extension NSScriptCommand {
    /// Records what the script reads back instead of a result.
    func refuse(_ number: Int, _ message: String) {
        scriptErrorNumber = number
        scriptErrorString = message
    }

    /// Records the core's refusal, in the number and words a script reads it as.
    func refuse(_ refusal: CommandError) {
        refuse(refusal.appleEventErrorNumber, refusal.appleEventErrorString)
    }
}
