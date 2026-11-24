import CoreServices
import Foundation
import KernovaCommandModel

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
        case .timedOut, .waitEnded(_, _, .timedOut):
            Int(errAETimeout)
        case .waitEnded(_, _, .removed):
            Int(errAENoSuchObject)
        case .invalidState, .changeTakesStoppedVM, .stepRequired, .unsupported, .unsupportedByBuild,
            .unsupportedByMacOS, .conflict,
            .confirmationRequired, .guestAccountPasswordRequired, .busy,
            .heldByAnotherCopy,
            .terminating, .waitEnded(_, _, .noAddressToWaitFor), .operationFailed, .filesKept,
            .shutdownNotCarriedOut, .restartCancelledByStop:
            Int(errAEEventFailed)
        }
    }

    /// What the script reads back: the words every other door shows, naming
    /// verbs as the dictionary does.
    ///
    /// A consent refusal gains `consenting`, the one thing a script can do
    /// about it — how the refused command gives that consent, as the `kernova`
    /// tool's own refusal names `--yes` — or nothing, for a command that gives
    /// none.
    func appleEventErrorString(consenting: String?) -> String {
        let message = message(in: .appleScript)
        guard case .confirmationRequired = self, let consenting else { return message }
        return message + "\n\n" + consenting
    }

    /// How a command that takes `with confirmation` gives a consent its verb
    /// refused without.
    static let withConfirmation = "Add `with confirmation` to do it anyway."
}

extension NSScriptCommand {
    /// The Cocoa key of `with confirmation`, on every command that takes it.
    package static let confirmationKey = "Confirmation"

    /// Records what the script reads back instead of a result.
    package func refuse(_ number: Int, _ message: String) {
        scriptErrorNumber = number
        scriptErrorString = message
    }

    /// Records the core's refusal, in the number and words a script reads it
    /// as: a consent refusal names `with confirmation` where this command
    /// takes it, and nothing where it doesn't.
    package func refuse(_ refusal: CommandError) {
        let takesConfirmation = commandDescription.argumentNames.contains(Self.confirmationKey)
        refuse(refusal, consenting: takesConfirmation ? CommandError.withConfirmation : nil)
    }

    /// Records the core's refusal, a consent refusal naming `consenting` as
    /// the way to give it (``CommandError/appleEventErrorString(consenting:)``).
    package func refuse(_ refusal: CommandError, consenting: String?) {
        refuse(refusal.appleEventErrorNumber, refusal.appleEventErrorString(consenting: consenting))
    }
}
