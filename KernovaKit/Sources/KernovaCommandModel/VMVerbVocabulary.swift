import Foundation

/// How one surface names the command core's verbs: its own name for each verb
/// it can run, and none for a verb it cannot.
///
/// A refusal's sentences that name a ``VMVerb`` as a command to run — what a
/// VM accepts now, how to answer for a VM a group action skipped — are worded
/// in one, so they name only what the surface showing them can run, in its
/// words. A surface writes its vocabulary as one `switch` over ``VMVerb``
/// with no `default:`, so a new verb fails to compile at every surface until
/// each answers for it.
public struct VMVerbVocabulary: Sendable {
    private let names: @Sendable (VMVerb) -> String?

    /// The vocabulary `names` answers.
    public init(_ names: @escaping @Sendable (VMVerb) -> String?) {
        self.names = names
    }

    /// This surface's name for `verb`, or `nil` when it cannot run it.
    public func name(of verb: VMVerb) -> String? {
        names(verb)
    }

    /// Each verb's raw value, for a log line: no person reads one as a
    /// surface's words.
    public static let log = VMVerbVocabulary { $0.rawValue }
}
